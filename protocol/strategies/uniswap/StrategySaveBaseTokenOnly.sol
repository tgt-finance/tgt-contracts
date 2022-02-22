// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "../../../utils/SafeToken.sol";
import "../../interfaces/IStrategy.sol";
import "../../interfaces/IRouter.sol";

contract StrategySaveBaseTokenOnly is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe, IStrategy {

  using SafeToken for address;
  using SafeMath for uint256;

  function initialize() public initializer {
    OwnableUpgradeSafe.__Ownable_init();
    ReentrancyGuardUpgradeSafe.__ReentrancyGuard_init();
  }

  /// @dev Execute worker strategy.
  function executeWithData(
    address /* user */,
    uint256 /* debt */,
    bytes calldata /* data */,
    bytes calldata _swapData
  )
    external override payable nonReentrant
  {
    (
      address baseToken,
      address farmToken,
      address router,
      address[] memory _path,
      uint256 amountOutMin
    ) = abi.decode(_swapData, (address, address, address, address[], uint256));

    // 1. Approve router to do their stuffs
    baseToken.safeApprove(router, uint256(-1));

    // 2. Convert base tokens to farm tokens.
    IRouter(router).swapExactTokensForTokens(
        baseToken.myBalance(),
        amountOutMin,
        _path,
        address(this),
        now
    );

    require(farmToken.myBalance() > 0, "swap farmToken is zero");

    // 3. Transfer Farm Token to Vault
    farmToken.safeTransfer(msg.sender, farmToken.myBalance());

    // 4. Reset approval for safety reason
    baseToken.safeApprove(router, 0);
  }
}
