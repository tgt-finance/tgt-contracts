// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";

import "./interfaces/IWorker.sol";
import "./interfaces/IVault.sol";
import "../utils/SafeToken.sol";
import "./WNativeRelayer.sol";
import "./library/SafeMathLib.sol";
import "./library/Address.sol";
import "./interfaces/IVaultConfig.sol";
import "./Exponential.sol";

interface IFToken {
  function borrowInternalForLeverage(address worker, uint256 amount) external;
  function repayInternalForLeverage(address worker, uint256 amount) external;
  function totalCash() external view returns (uint256);
  function addReservesForLeverage(uint addAmount) external;
}

contract Vault is IVault, Exponential, OwnableUpgradeSafe {

  using SafeToken for address;
  using AddressLib for address;
  using SafeMathLib for uint256;

  event AddDebt(uint256 indexed id, uint256 debtShare);
  event RemoveDebt(uint256 indexed id, uint256 debtShare);
  event Work(uint256 indexed id, address indexed worker, address owner, uint256 principal, uint256 loan, uint256 health, uint256 shares, uint256 deposit, uint256 withdraw, uint256 timestamp);
  event Kill(uint256 indexed id, address indexed killer, address owner, uint256 posVal, uint256 debt, uint256 prize, uint256 left);

  IVaultConfig public config;

  /// @dev Flags for manage execution scope
  uint256 private constant _NOT_ENTERED = 1;
  uint256 private constant _ENTERED = 2;
  uint256 private constant _NO_ID = uint(-1);
  address private constant _NO_ADDRESS = address(1);
  uint256 private beforeLoan;
  uint256 private afterLoan;

  /// @dev Temporay variables to manage execution scope
  uint256 public _IN_EXEC_LOCK;
  uint256 public POSITION_ID;
  address public STRATEGY;

  address public token;
  address public ftoken;
  uint256 public vaultDebtShare;
  uint256 public vaultDebtVal;

  uint256 public securityFactor;
  uint256 public reserveFactor;

  struct Position {
    address worker;
    address owner;
    uint256 debtShare;
    uint256 id;
  }

  struct WorkEntity {
    address worker;
    uint256 principalAmount;
    uint256 loan;
    uint256 maxReturn;
  }

  struct PositionRecord {
    uint256 deposit;
    uint256 withdraw;
  }
  mapping (uint256 => Position) public positions;
  mapping (uint256 => uint256) public positionToLoan;
  uint256 public nextPositionID;
  uint256 public lastAccrueTime;
  // user => worker => position
  mapping (address => mapping (address => Position)) public userToPositions;
  // user => worker => positionId
  mapping (address => mapping (address => uint256)) public userToPositionId;
  // user => worker => Position
  mapping (address => mapping (address => PositionRecord)) public userToPositionRecord;

  /// @dev Get token from msg.sender
  modifier transferTokenToVault(uint256 value) {
    if (msg.value != 0) {
      require(token == config.getWrappedNativeAddr(), "transferTokenToVault:: baseToken is not wNative");
      require(value == msg.value, "transferTokenToVault:: value != msg.value");
      IWETH(config.getWrappedNativeAddr()).deposit{value: msg.value}();
    } else {
      SafeToken.safeTransferFrom(token, msg.sender, address(this), value);
    }
    _;
  }

  /// @dev Add more debt to the bank debt pool.
  modifier accrue(uint256 value) {
    if (now > lastAccrueTime) {
      uint256 interest = pendingInterest(value);
      vaultDebtVal = vaultDebtVal.add(interest);
      lastAccrueTime = now;
    }
    _;
  }

  /// @dev Update bank configuration to a new address. Must only be called by owner.
  /// @param _config The new configurator address.
  function updateConfig(IVaultConfig _config) external onlyOwner {
    config = _config;
  }

  /// @dev security Part in 10000 eg: 100/10000, reserve decimals is 1e18 eg: 1e17
  function updateSecurityAndReserveFactor(uint256 _securityFactor, uint256 _reserveFactor) external onlyOwner {
    securityFactor = _securityFactor;
    reserveFactor = _reserveFactor;
  }

  /// initialize
  function initialize(
    IVaultConfig _config,
    address _token,
    address _ftoken
  ) public initializer {
    OwnableUpgradeSafe.__Ownable_init();

    config = IVaultConfig(_config);
    ftoken = _ftoken;

    securityFactor = 100;
    reserveFactor = 1e17;

    nextPositionID = 1;
    lastAccrueTime = now;
    token = _token;

    // free-up execution scope
    _IN_EXEC_LOCK = _NOT_ENTERED;
    POSITION_ID = _NO_ID;
    STRATEGY = _NO_ADDRESS;
  }

  /// Return the pending interest that will be accrued in the next call.
  /// _value Balance value to subtract off address(this).balance when called from payable functions.
  function pendingInterest(uint256 _value) public view returns (uint256) {
    if (now > lastAccrueTime) {
      uint256 timePast = SafeMathLib.sub(now, lastAccrueTime, "timePast");
      uint256 balance = SafeMathLib.sub(SafeToken.myBalance(token), _value, "pendingInterest: balance");
      uint256 ratePerSec = config.getInterestRate(balance, vaultDebtVal);
      return ratePerSec.mul(vaultDebtVal).mul(timePast).div(1e18);
    } else {
      return 0;
    }
  }

  /// @dev Return the Token debt value given the debt share. Be careful of unaccrued interests.
  /// @param debtShare The debt share to be converted.
  function debtShareToVal(uint256 debtShare) public view returns (uint256) {
    if (vaultDebtShare == 0) return debtShare; // When there's no share, 1 share = 1 val.
    return debtShare.mul(vaultDebtVal).div(vaultDebtShare);
  }

  /// @dev Return the debt share for the given debt value. Be careful of unaccrued interests.
  /// @param debtVal The debt value to be converted.
  function debtValToShare(uint256 debtVal) public view returns (uint256) {
    if (vaultDebtShare == 0) return debtVal; // When there's no share, 1 share = 1 val.
    return debtVal.mul(vaultDebtShare).div(vaultDebtVal);
  }

  /// @dev Return Token value and debt of the given position. Be careful of unaccrued interests.
  /// @param id The position ID to query.
  function positionInfo(uint256 id) public view returns (uint256, uint256) {
    Position storage pos = positions[id];
    return (IWorker(pos.worker).health(id), debtShareToVal(pos.debtShare));
  }

  /// @dev Create/Modify a position.
  /// @param id The ID of the position. Use ZERO for new position.
  /// @param workEntity The amount of Token to borrow from the pool.
  /// @param data The calldata to pass along to the worker for more working context.
  /// @param swapData Swap data
  function work(
    uint id,
    WorkEntity calldata workEntity,
    bytes calldata data,
    bytes calldata swapData
  )
    external payable
   transferTokenToVault(workEntity.principalAmount) accrue(workEntity.principalAmount)
  {
    Position storage pos;
    if (id == 0) {
      id = nextPositionID++;
      pos = positions[id];
      pos.id = id;
      pos.worker = workEntity.worker;
      require(userToPositionId[msg.sender][pos.worker] == 0, "user has position");
      userToPositions[msg.sender][pos.worker] = pos;
      userToPositionId[msg.sender][pos.worker] = id;
      pos.owner = msg.sender;
    } else {
      pos = positions[id];
      require(id < nextPositionID, "bad position id");
      require(pos.worker == workEntity.worker, "bad position worker");
      require(pos.owner == msg.sender, "not position owner");
    }

    POSITION_ID = id;
    (STRATEGY, ) = abi.decode(data, (address, bytes));

    require(config.isWorker(workEntity.worker), "not a worker");
    require(workEntity.loan == 0 || config.acceptDebt(workEntity.worker), "worker not accept more debt");
    beforeLoan = positionToLoan[id];
    uint256 debt = _removeDebt(id).add(workEntity.loan);
    afterLoan = beforeLoan.add(workEntity.loan);

    uint256 tokenReceivedFromWorker;
    {
      if (workEntity.principalAmount > 0) {
        PositionRecord storage record;
        record = userToPositionRecord[msg.sender][pos.worker];
        record.deposit = record.deposit.add(workEntity.principalAmount);
      }
      if (workEntity.loan > 0) {
        IFToken(ftoken).borrowInternalForLeverage(pos.worker, workEntity.loan);
      }
      uint256 tokenAmountToWorker = workEntity.principalAmount.add(workEntity.loan);
      require(tokenAmountToWorker <= SafeToken.myBalance(token), "insufficient funds in the vault");
      uint256 tokenAmountBeforeSend = SafeMathLib.sub(SafeToken.myBalance(token), tokenAmountToWorker, "tokenAmountBeforeSend");
      SafeToken.safeTransfer(token, workEntity.worker, tokenAmountToWorker);
      IWorker(workEntity.worker).workWithData(id, msg.sender, debt, data, swapData);
      tokenReceivedFromWorker = SafeMathLib.sub(SafeToken.myBalance(token), tokenAmountBeforeSend, "tokenReceivedFromWorker");
    }
    uint256 lessDebt = Math.min(debt, tokenReceivedFromWorker);
    if (lessDebt > 0) {
      SafeToken.safeApprove(token, ftoken, uint(-1));
      uint256 interest = SafeMathLib.sub(debt, afterLoan);
      uint256 reserveFund = divExp(mulExp(reserveFactor, interest), expScale);
      IFToken(ftoken).repayInternalForLeverage(pos.worker, reserveFund);
      IFToken(ftoken).addReservesForLeverage(reserveFund);
      SafeToken.safeTransfer(token, ftoken, SafeMathLib.sub(lessDebt, interest + reserveFund));
      SafeToken.safeApprove(token, ftoken, uint(0));
      afterLoan = SafeMathLib.sub(afterLoan, SafeMathLib.sub(lessDebt, interest));
    }
    debt = SafeMathLib.sub(debt, lessDebt, "debt");
    if (debt > 0) {
      require(debt >= config.minDebtSize(), "too small debt size");
      uint256 health = IWorker(workEntity.worker).health(id);
      uint256 workFactor = config.workFactor(workEntity.worker, debt);
      require(health.mul(workFactor) >= debt.mul(10000), "positoin < debt");
      _addDebt(id, debt);
    }

    if (tokenReceivedFromWorker > lessDebt) {
      if(token == config.getWrappedNativeAddr()) {
        SafeToken.safeTransfer(token, config.getWNativeRelayer(), tokenReceivedFromWorker.sub(lessDebt));
        WNativeRelayer(uint160(config.getWNativeRelayer())).withdraw(tokenReceivedFromWorker.sub(lessDebt));
        SafeToken.safeTransferETH(msg.sender, tokenReceivedFromWorker.sub(lessDebt));
      } else {
        SafeToken.safeTransfer(token, msg.sender, tokenReceivedFromWorker.sub(lessDebt));
      }
      PositionRecord storage record;
      record = userToPositionRecord[msg.sender][pos.worker];
      record.withdraw = record.withdraw.add(tokenReceivedFromWorker.sub(lessDebt));
    }

    if (IWorker(workEntity.worker).getShares(id) == 0) {
      userToPositionRecord[msg.sender][pos.worker].deposit = 0;
      userToPositionRecord[msg.sender][pos.worker].withdraw = 0;
    }

    emit Work(
      pos.id,
      pos.worker,
      pos.owner,
      workEntity.principalAmount,
      workEntity.loan,
      IWorker(pos.worker).health(pos.id),
      IWorker(pos.worker).getShares(pos.id),
      userToPositionRecord[msg.sender][pos.worker].deposit,
      userToPositionRecord[msg.sender][pos.worker].withdraw,
      block.timestamp
    );

    POSITION_ID = _NO_ID;
    STRATEGY = _NO_ADDRESS;
    beforeLoan = 0;
    afterLoan = 0;
  }

  /// @dev Kill the given to the position. Liquidate it immediately if killFactor condition is met.
  /// @param id The position ID to be killed.
  /// @param swapData Swap token data in the dex protocol.
  function kill(uint256 id, bytes calldata swapData) external accrue(0) {
    require(!address(msg.sender).isContract(), "Not EOA");
    Position storage pos = positions[id];
    require(pos.debtShare > 0, "kill:: no debt");

    uint256 debt = _removeDebt(id);
    uint256 health = IWorker(pos.worker).health(id);
    uint256 killFactor = config.killFactor(pos.worker, debt);

    require(health.mul(killFactor) < debt.mul(10000), "kill:: postion > debt");

    uint256 back;
    {
      uint256 beforeToken = SafeToken.myBalance(token);
      IWorker(pos.worker).liquidateWithData(id, swapData);
      back = SafeToken.myBalance(token).sub(beforeToken);
    }
    // 5% of the liquidation value will become Clearance Fees
    uint256 clearanceFees = back.mul(config.getKillBps()).div(10000);
    // clearanceFees will be distributed to 4 parts:
    // 30% for liquidator reward
    uint256 prize = clearanceFees.mul(securityFactor).div(10000);
    // 30% for protocol token stakers reward
    // 30% to be converted to ProtocolToken/USDT LP Pair on Dex
    // 10% to security fund
    uint256 securityFund = clearanceFees.sub(prize);

    uint256 rest = back.sub(clearanceFees);
    // Clear position debt and return funds to liquidator and position owner.
    if (prize > 0) {
      if (token == config.getWrappedNativeAddr()) {
        SafeToken.safeTransfer(token, config.getWNativeRelayer(), prize);
        WNativeRelayer(uint160(config.getWNativeRelayer())).withdraw(prize);
        SafeToken.safeTransferETH(msg.sender, prize);
      } else {
        SafeToken.safeTransfer(token, msg.sender, prize);
      }
    }

    if (securityFund > 0) {
      SafeToken.safeApprove(token, ftoken, securityFund);
      IFToken(ftoken).addReservesForLeverage(securityFund);
    }

    uint256 lessDebt = Math.min(debt, back);
    debt = SafeMathLib.sub(debt, lessDebt, "debt");
    if (debt > 0) {
      _addDebt(id, debt);
    }
    uint256 left = rest > debt ? rest - debt : 0;
    if (left > 0) {
      if (token == config.getWrappedNativeAddr()) {
        SafeToken.safeTransfer(token, config.getWNativeRelayer(), left);
        WNativeRelayer(uint160(config.getWNativeRelayer())).withdraw(left);
        SafeToken.safeTransferETH(pos.owner, left);
      } else {
        SafeToken.safeTransfer(token, pos.owner, left);
      }
    }

    if (IWorker(pos.worker).getShares(pos.id) == 0) {
      userToPositionRecord[msg.sender][pos.worker].deposit = 0;
      userToPositionRecord[msg.sender][pos.worker].withdraw = 0;
    }
    emit Kill(id, msg.sender, pos.owner, health, debt, prize, left);
  }

  // Internal function to add the given debt value to the given position.
  function _addDebt(uint256 id, uint256 debtVal) internal {
    Position storage pos = positions[id];
    uint256 debtShare = debtValToShare(debtVal);
    pos.debtShare = pos.debtShare.add(debtShare);
    vaultDebtShare = vaultDebtShare.add(debtShare);
    vaultDebtVal = vaultDebtVal.add(debtVal);

    positionToLoan[id] = afterLoan;
    userToPositions[msg.sender][pos.worker].debtShare = pos.debtShare;

    emit AddDebt(id, debtShare);
  }

  // Internal function to clear the debt of the given position. Return the debt value.
  function _removeDebt(uint256 id) internal returns (uint256) {
    Position storage pos = positions[id];
    uint256 debtShare = pos.debtShare;
    if (debtShare > 0) {
      uint256 debtVal = debtShareToVal(debtShare);
      pos.debtShare = 0;
      vaultDebtShare = SafeMathLib.sub(vaultDebtShare, debtShare, "vaultDebtShare");
      vaultDebtVal = SafeMathLib.sub(vaultDebtVal, debtVal, "vaultDebtVal");

      positionToLoan[id] = 0;
      userToPositions[msg.sender][pos.worker].debtShare = 0;

      emit RemoveDebt(id, debtShare);
      return debtVal;
    } else {
      return 0;
    }
  }

  // Fallback function to accept ETH.
  receive() external payable {
    require(msg.value > 0, "value must > 0");
  }
}
