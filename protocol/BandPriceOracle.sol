// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./IPriceOracle.sol";
import "./interfaces/IStdReference.sol";

contract BandPriceOracle is IPriceOracle, OwnableUpgradeSafe {

  IStdReference public ref;
  uint256 public price;

  mapping(address => string) public tokensMap;
  address public baseToken;

  function initialize(IStdReference _ref) public initializer {
    __Ownable_init();
    ref = _ref;
  }

  function setTokenName(address[] calldata tokensAddr, string[] calldata symbol) external onlyOwner {
    require(tokensAddr.length == symbol.length, "length must equal");
    for (uint256 i = 0; i < tokensAddr.length; i++) {
      tokensMap[tokensAddr[i]] = symbol[i];
    }
  }

  function setBaseToken(address newBaseToken) external onlyOwner {
    baseToken = newBaseToken;
  }

  function getPrice(address token0, address token1) public override view returns (uint256 price, uint256 lastUpdate) {
    string memory symbol0 = tokensMap[token0];
    string memory symbol1 = tokensMap[token1];
    require(bytes(symbol0).length != 0 && bytes(symbol1).length != 0, "token address is not set");

    IStdReference.ReferenceData memory data = ref.getReferenceData(symbol0, symbol1);
    return (data.rate, block.timestamp);
  }

  function get(address token) external override view returns (uint256, bool) {
    (uint256 price,) = getPrice(token, baseToken);
    return (price, true);
  }
}
