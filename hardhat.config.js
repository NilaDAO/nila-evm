require("dotenv").config();
require("@nomicfoundation/hardhat-toolbox");
require("@nomicfoundation/hardhat-ledger");
require("@openzeppelin/hardhat-upgrades");

// No keys or RPC URLs in this file: they come from the environment (.env, never committed).
// The FoodToken proxy is owned by a Ledger; upgrades run only with the `polygon-ledger` network.
// Set POLYGON_RPC_URL to your own endpoint; there is no working public default.
const RPC = process.env.POLYGON_RPC_URL || "";

module.exports = {
  solidity: {
    version: "0.8.25",
    // Same settings as the deployed implementations: an upgrade must compile identically.
    settings: {
      viaIR: true,
      optimizer: { enabled: true, runs: 1 },
      metadata: { bytecodeHash: "none" },
      evmVersion: "paris",
    },
  },
  networks: {
    hardhat: {},
    polygon: { url: RPC, chainId: 137 },
    "polygon-ledger": {
      url: RPC,
      chainId: 137,
      ledgerAccounts: process.env.LEDGER_ACCOUNT ? [process.env.LEDGER_ACCOUNT] : [],
    },
  },
};
