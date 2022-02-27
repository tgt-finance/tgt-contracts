// SPDX-License-Identifier: MIT

// This contract intends to use uniswap v2 and Band protocol work with vault and strategies
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
    uint256 farmTokenShares = shares[id];
    uint256 baseTokenDecimal = IERC20(baseToken).decimals();
    uint256 farmTokenDecimal = IERC20(farmToken).decimals();
    (uint256 baseTokenPrice, uint256 farmTokenPrice,,) = getPrices();

    // baseTokenAmount = farmTokenShares * farmTokenPrice * baseTokenDecimal / baseTokenPrice / farmTokenDecimal
    uint256 farmTokenValue = SafeMathLib.mul(farmTokenPrice, farmTokenShares);
    uint256 farmTokenValuePrecision = SafeMathLib.mul(10**baseTokenDecimal, farmTokenValue);
    return SafeMathLib.div(SafeMathLib.div(farmTokenValuePrecision, baseTokenPrice), 10**farmTokenDecimal);
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

  // get baseToken and farmToken price against USD from BAND oracle
  function getPrices() public view returns (uint256, uint256, uint256, uint256) {
    string memory baseTokenSymbol = baseToken == usd ? "USD" : IERC20(baseToken).symbol();
    string memory farmTokenSymbol = farmToken == usd ? "USD" : IERC20(farmToken).symbol();

    IStdReference.ReferenceData memory baseTokenPriceData = ref.getReferenceData(baseTokenSymbol, 'USD');
    IStdReference.ReferenceData memory farmTokenPriceData = ref.getReferenceData(farmTokenSymbol, 'USD');
    // TODO: check if the price is valid
    // require(block.timestamp - baseTokenPriceData.lastUpdatedQuote > 3600, "baseToken price not updated");
    // require(block.timestamp - farmTokenPriceData.lastUpdatedQuote > 3600, "farmToken price not updated");
    return (baseTokenPriceData.rate, farmTokenPriceData.rate, baseTokenPriceData.lastUpdatedQuote, farmTokenPriceData.lastUpdatedQuote);
  }

  function getShares(uint256 id) external override view returns (uint256) {
    return shares[id];
  }
}