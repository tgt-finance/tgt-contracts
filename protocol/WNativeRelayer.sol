// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;

import "./interfaces/IWETH.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract WNativeRelayer is OwnableUpgradeSafe, ReentrancyGuardUpgradeSafe {
  address public wnative;
  mapping(address => bool) okCallers;

  function initialize(address _wnative) public initializer {
    __Ownable_init();
    __ReentrancyGuard_init();

    wnative = _wnative;
  }

  modifier onlyWhitelistedCaller() {
    require(okCallers[msg.sender] == true, "WNativeRelayer::onlyWhitelistedCaller:: !okCaller");
    _;
  }

  function setCallerOk(address[] calldata whitelistedCallers, bool isOk) external onlyOwner {
    uint256 len = whitelistedCallers.length;
    for (uint256 idx = 0; idx < len; idx++) {
      okCallers[whitelistedCallers[idx]] = isOk;
    }
  }

  function withdraw(uint256 _amount) public onlyWhitelistedCaller nonReentrant {
    IWETH(wnative).withdraw(_amount);
    (bool success, ) = msg.sender.call{value: _amount}("");
    require(success, "WNativeRelayer::onlyWhitelistedCaller:: can't withdraw");
  }

  receive() external payable {
      require(msg.sender == wnative, "WNativeRelayer::onlyWnative");
  }
}