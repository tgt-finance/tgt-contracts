// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";

import "../../interfaces/IStrategy.sol";
import "../../../utils/SafeToken.sol";
import "../../interfaces/IRouter.sol";

contract StrategyWithdrawTrading is ReentrancyGuardUpgradeSafe, IStrategy {
  using SafeToken for address;

  function initialize() public initializer {
    __ReentrancyGuard_init();
  }

  /// Execute worker strategy.
  function executeWithData(
    address /* user */,
    uint256 /* debt */,
    bytes calldata /* _data */,
    bytes calldata _swapData
  )
    external override payable nonReentrant
  {
    (
      address baseToken,
      address farmToken,
      address router,
      address[] memory _path,
      uint256 amountIn,
      uint256 amountOutMin
    ) = abi.decode(_swapData, (address, address, address, address[], uint256, uint256));

    // 1. Approve router to do their stuffs
    farmToken.safeApprove(router, uint256(-1));

    // 2. Convert farm tokens to base tokens.
    IRouter(router).swapExactTokensForTokens(
      amountIn,
      amountOutMin,
      _path,
      address(this),
      now
    );

    require(baseToken.myBalance() > 0, "swap baseToken is zero");
    // 3. Transfer Farm Token to Vault
    baseToken.safeTransfer(msg.sender, baseToken.myBalance());
    farmToken.safeTransfer(msg.sender, farmToken.myBalance());

    // 4. Reset approval for safety reason
    farmToken.safeApprove(router, 0);
  }
}
