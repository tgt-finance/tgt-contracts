import "@openzeppelin/hardhat-upgrades";
import "@nomiclabs/hardhat-waffle";
import "hardhat-typechain";
import "hardhat-deploy";
import "solidity-coverage";
import "hardhat-abi-exporter";
import "hardhat-contract-sizer";

module.exports = {
  defaultNetwork: 'hardhat',
  networks: {
    hardhat: {
      chainId: 31337,
      gas: 12000000,
      blockGasLimit: 0x1fffffffffffff,
      allowUnlimitedContractSize: true
    },
  },
  solidity: {
    compilers: [
      {
        version: '0.6.6',
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          outputSelection: {
            "*": {
              "": [
                "ast"
              ],
              "*": [
                "evm.bytecode.object",
                "evm.deployedBytecode.object",
                "abi",
                "evm.bytecode.sourceMap",
                "evm.deployedBytecode.sourceMap",
                "metadata"
              ]
            }
          },
        }
      },
      {
        version: "0.8.4",
        settings: {
          optimizer: { enabled: true, runs: 200 }
        }
      }
    ]
  },
  paths: {
    sources: './contracts',
    tests: './test',
    cache: './cache',
    artifacts: './artifacts',
  },
  typechain: {
    outDir: './typechain',
    target: 'ethers-v5',
  },
  abiExporter: {
    path: './abi',
    clear: false,
    flat: true
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: false,
    strict: true,
  },
  mocha: {
    timeout: 100000
  }
};