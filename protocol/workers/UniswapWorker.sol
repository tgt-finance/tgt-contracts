// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IERC20.sol";
import "../interfaces/IStrategy.sol";
import "../interfaces/IWorker.sol";
import "../interfaces/IStdReference.sol";
import "../library/SafeMathLib.sol";
import "../library/FullMath.sol";
import "../library/TickMath.sol";
import "../library/FixedPoint96.sol";
import "../../utils/SafeToken.sol";

interface ITokenVault {
  function deposit(address _token, uint _amount) external;
  function withdraw(address _token, uint256 _amount, address _receiver) external;
}

contract UniswapWorker is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, IWorker {

  using SafeToken for address;

  // Events
  event AddShare(uint256 indexed id, uint256 share);
  event RemoveShare(uint256 indexed id, uint256 share);
  event Liquidate(uint256 indexed id, uint256 wad);

  address public tokenVault;
  address public wNative;
  address public baseToken;
  address public farmToken;
  address public operator;

  IStdReference public ref;

  mapping(uint256 => uint256) public shares;
  mapping(address => bool) public okStrats;
  uint256 public totalShare;
  IStrategy public addStrat;
  IStrategy public liqStrat;

  address public usd;

  function initialize(
    address _operator,
    address _baseToken,
    address _farmToken,
    address _tokenVault,
    IStrategy _addStrat,
    IStrategy _liqStrat,
    IStdReference _ref
  ) public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();

    operator = _operator;

    baseToken = _baseToken;
    farmToken = _farmToken;
    tokenVault = _tokenVault;

    addStrat = _addStrat;
    liqStrat = _liqStrat;
    okStrats[address(addStrat)] = true;
    okStrats[address(liqStrat)] = true;

    ref = _ref;
    usd = address(0xEeeeeeeEEEeEEeeEEeeEEeEEEEEeeEEEeeEeEeed);
  }

  function setParams(
    IStrategy _addStrat,
    IStrategy _liqStrat
  )
    external onlyOwner
  {
    addStrat = _addStrat;
    liqStrat = _liqStrat;

    okStrats[address(addStrat)] = true;
    okStrats[address(liqStrat)] = true;
  }

  modifier onlyEOA() {
    require(msg.sender == tx.origin, "worker not eoa");
    _;
  }

  modifier onlyOperator() {
    require(msg.sender == operator, "worker::not operator");
    _;
  }

  /// @dev Work on the given position. Must be called by the operator.
  /// @param id The position ID to work on.
  /// @param user The original user that is interacting with the operator.
  /// @param debt The amount of user debt to help the strategy make decisions.
  /// @param data The encoded data, consisting of strategy address and calldata.
  function workWithData(
    uint256 id,
    address user,
    uint256 debt,
    bytes calldata data,
    bytes calldata swapData
  )
    override external onlyOperator nonReentrant
  {
    _removeShare(id);

    (address strat, bytes memory ext) = abi.decode(data, (address, bytes));
    require(okStrats[strat], "unapproved work strategy");

    if (baseToken.myBalance() > 0) {
      baseToken.safeTransfer(strat, baseToken.myBalance());
    }
    if (farmToken.myBalance() > 0) {
      farmToken.safeTransfer(strat, farmToken.myBalance());
    }
    IStrategy(strat).executeWithData(user, debt, ext, swapData);

    _addShare(id);

    baseToken.safeTransfer(msg.sender, baseToken.myBalance());
  }

  /// @dev Return the amount of BaseToken to receive if we are to liquidate the given position.
  /// @param id The position ID to perform health check.
  function health(uint256 id) external override view returns (uint256) {
    uint256 positions = shares[id];

    uint256 token0Decimal = IERC20(baseToken).decimals();
    uint256 token1Decimal = IERC20(farmToken).decimals();

    uint256 price0 = getLastPrice(farmToken, baseToken);
    // farmToken -> baseToken  price0 decimal equal 1e18
    uint256 baseTokenAmount = SafeMathLib.mul(price0, positions);
    uint256 tmpAmount = SafeMathLib.mul(baseTokenAmount, 10**token0Decimal);
    uint256 receiveBaseAmount = SafeMathLib.div(SafeMathLib.div(tmpAmount, 10**token1Decimal), 1e18);
    return receiveBaseAmount;
  }

  /// @dev Liquidate the given position by converting it to BaseToken and return back to caller.
  /// @param id The position ID to perform liquidation
  /// @param data Swap token data in the dex protocol.
  function liquidateWithData(uint256 id, bytes calldata data) external override onlyOperator nonReentrant {

    (uint256 closeShare, bytes memory swapData) = abi.decode(data, (uint256, bytes));
    // 1. Withdraw farm tokens and use liquidate strategy.
    _removeShare(id, closeShare);

    farmToken.safeTransfer(address(liqStrat), farmToken.balanceOf(address(this)));
    liqStrat.executeWithData(address(0), 0, abi.encode(baseToken, farmToken, 0), swapData);

    // 2. Return all available BaseToken back to the operator.
    uint256 wad = baseToken.myBalance();
    baseToken.safeTransfer(msg.sender, wad);

    emit Liquidate(id, wad);
  }

  /// @dev Internal function to stake all outstanding farm tokens to the given position ID.
  function _addShare(uint256 id) internal {
    uint256 balance = farmToken.balanceOf(address(this));
    if (balance > 0) {
      // 1. Approve token to be spend by tokenVault
      address(farmToken).safeApprove(address(tokenVault), uint256(-1));

      // 2. Deposit balance to tokenVault
      ITokenVault(tokenVault).deposit(farmToken, balance);

      // 3. Update shares
      shares[id] = SafeMathLib.add(shares[id], balance);
      totalShare = SafeMathLib.add(totalShare, balance);

      // 4. Reset approve token
      address(farmToken).safeApprove(address(tokenVault), 0);
      emit AddShare(id, balance);
    }
  }

  /// @dev Internal function to remove shares of the ID.
  function _removeShare(uint256 id) internal {
    uint256 share = shares[id];
    if (share > 0) {
      ITokenVault(tokenVault).withdraw(farmToken, share, address(this));
      totalShare = SafeMathLib.sub(totalShare, share, "worker:totalShare");
      shares[id] = 0;
      emit RemoveShare(id, share);
    }
  }

  /// @dev Internal function to remove shares of the ID.
  function _removeShare(uint256 id, uint256 closeShare) internal {
    uint256 share = shares[id];

    if (share >= closeShare) {
      ITokenVault(tokenVault).withdraw(farmToken, closeShare, address(this));
      totalShare = SafeMathLib.sub(totalShare, closeShare, "worker:totalShare");
      shares[id] = SafeMathLib.sub(shares[id], closeShare, "worker:sub shares");
      emit RemoveShare(id, closeShare);
    } else {
      _removeShare(id);
    }
  }

  /// @dev Set the given strategies' approval status.
  /// @param strats The strategy addresses.
  /// @param isOk Whether to approve or unapprove the given strategies.
  function setStrategyOk(address[] calldata strats, bool isOk) external override onlyOwner {
    uint256 len = strats.length;
    for (uint256 idx = 0; idx < len; idx++) {
      okStrats[strats[idx]] = isOk;
    }
  }

  function getOraclePrice(address token0, address token1) public view returns (uint256, uint256) {
    string memory token0Symbol = baseToken == usd ? "USD" : IERC20(baseToken).symbol();
    string memory token1Symbol = farmToken == usd ? "USD" : IERC20(farmToken).symbol();
    if (farmToken == usd) {
      IStdReference.ReferenceData memory data = ref.getReferenceData(token0Symbol, token1Symbol);
      return (data.rate, block.timestamp);
    } else {
      IStdReference.ReferenceData memory data = ref.getReferenceData(token1Symbol, token0Symbol);
      return (SafeMathLib.div(1e36, data.rate), block.timestamp);
    }
  }

  function getLastPrice(address token0, address token1) public view returns (uint256) {
      if (farmToken == token0) {
        (uint price0,) = getOraclePrice(token0, usd);
        (uint price1,) = getOraclePrice(usd, token1);
        return SafeMathLib.div(SafeMathLib.mul(price0, price1), 1e18);
      } else {
        (uint price0,) = getOraclePrice(usd, token0);
        (uint price1,) = getOraclePrice(token1, usd);
        return SafeMathLib.div(SafeMathLib.mul(price0, price1), 1e18);
      }
  }

  function getShares(uint256 id) external override view returns (uint256) {
    return shares[id];
  }
}