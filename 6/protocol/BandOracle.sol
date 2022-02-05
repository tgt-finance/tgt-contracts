// SPDX-License-Identifier: MIT
pragma solidity 0.6.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

import "./IPriceOracle.sol";


interface IStdReference {
  /// A structure returned whenever someone requests for standard reference data.    
  struct ReferenceData {        
    uint256 rate;             // base/quote exchange rate, multiplied by 1e18.        
    uint256 lastUpdatedBase;  // UNIX epoch of the last time when base price gets updated.        
    uint256 lastUpdatedQuote; // UNIX epoch of the last time when quote price gets updated.    
  }

  /// Returns the price data for the given base/quote pair. Revert if not available.    
  function getReferenceData(string calldata _base, string calldata _quote) external view returns (ReferenceData memory);   
  /// Similar to getReferenceData, but with multiple base/quote pairs at once.    
  function getReferenceDataBulk(string[] calldata _bases, string[] calldata _quotes) external view returns (ReferenceData[] memory);
}

contract BandOracle is IPriceOracle, OwnableUpgradeSafe {    

  IStdReference public ref;
  uint256 public price;
  
  mapping(address => string) public tokensMap;
  address public baseToken;

  function initialize(IStdReference _ref) public initializer {
    OwnableUpgradeSafe.__Ownable_init();
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

  // TODO remove this funcion when release version
  function getMultiPrices() external view returns (uint256[] memory) {
    string[] memory baseSymbols = new string[](2);        
    baseSymbols[0] = "BNB";        
    baseSymbols[1] = "ETH";        
    string[] memory quoteSymbols = new string[](2);        
    quoteSymbols[0] = "USD";        
    quoteSymbols[1] = "USD";        
    IStdReference.ReferenceData[] memory data = ref.getReferenceDataBulk(baseSymbols, quoteSymbols);        
    uint256[] memory prices = new uint256[](2);        
    prices[0] = data[0].rate;        
    prices[1] = data[1].rate;        
    return prices;
  }
}
