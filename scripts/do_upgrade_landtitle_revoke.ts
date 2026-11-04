// Upgrade NilaLandTitle — revokeTitle (4 Nov 2026, executive decision): a union leader removes a member, or a
// member burns her own title; the title goes to 0x…dEaD and the node attests the change on Stellar. revokeTitle is
// callable by a whitelisted signer (the node's title key) or the owner, without the holder's approval.
// Adds one function, one event and one constant; NO new state variables; no reinitializer, no migration.
//
// SIGNER: the owner of this proxy is the EXECUTIVE WALLET 0xF2Ea7D0870051903a64c075c22E95FB816d4fA64
// (EIP-7702 MetaMask smart account) — NOT the Ledger. The `polygon-ledger` network cannot sign this upgrade.
// By default this script only VALIDATES (and, with PREPARE=1, deploys the new implementation via prepareUpgrade,
// which any funded account may do). The upgrade itself is `upgradeToAndCall(newImpl, "0x")` on the proxy, sent
// by the executive wallet from MetaMask; the script prints the calldata for that.
// UPGRADE=1 sends upgradeProxy and only works when the configured signer IS the owner.
// MAINNET ONLY WITH AN EXECUTIVE GO. Claude Code never runs this script.
//
// Validate only (no tx):   npx hardhat run scripts/do_upgrade_landtitle_revoke.ts --network polygon
// Deploy impl (no upgrade): PREPARE=1 npx hardhat run scripts/do_upgrade_landtitle_revoke.ts --network polygon
// After the upgrade: the node's title key 0xB27773f8940A041221A4a54C77b823E80974cCCB is already whitelisted.

const { ethers, upgrades } = require("hardhat");

const LANDTITLE_PROXY = "0x636060dbC695a8232992b28c1765828263f17251";
const EXPECTED_OWNER = "0xF2Ea7D0870051903a64c075c22E95FB816d4fA64";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function implOf(proxy: string): Promise<string> {
  const raw = await ethers.provider.getStorage(proxy, IMPL_SLOT);
  return ethers.getAddress("0x" + raw.slice(26));
}

async function main() {
  const signers = await ethers.getSigners();
  const lt = await ethers.getContractAt("NilaLandTitle", LANDTITLE_PROXY);
  const proxyOwner = await lt.owner();
  console.log(`Block       : ${await ethers.provider.getBlockNumber()}`);
  console.log(`Proxy owner : ${proxyOwner}`);
  if (proxyOwner.toLowerCase() !== EXPECTED_OWNER.toLowerCase()) {
    console.warn(`WARNING: owner differs from the recorded executive wallet ${EXPECTED_OWNER}`);
  }
  console.log(`Impl BEFORE : ${await implOf(LANDTITLE_PROXY)}`);

  const F = await ethers.getContractFactory("NilaLandTitle");
  await upgrades.validateUpgrade(LANDTITLE_PROXY, F, { kind: "uups" });
  console.log("validateUpgrade ✅ (no new state variables)");

  if (process.env.UPGRADE === "1") {
    const signer = signers[0];
    if (!signer || (await signer.getAddress()).toLowerCase() !== proxyOwner.toLowerCase()) {
      throw new Error(`UPGRADE=1 needs the proxy owner as signer (${proxyOwner}). Use PREPARE=1 + MetaMask instead.`);
    }
    await upgrades.upgradeProxy(LANDTITLE_PROXY, F.connect(signer), { kind: "uups", redeployImplementation: "always" });
    console.log(`Impl AFTER  : ${await implOf(LANDTITLE_PROXY)}`);
    return;
  }

  if (process.env.PREPARE !== "1") { console.log("Validate only: no tx sent."); return; }
  if (!signers[0]) throw new Error("PREPARE=1 needs a funded deployer account configured for this network.");
  const newImpl = (await upgrades.prepareUpgrade(LANDTITLE_PROXY, F.connect(signers[0]), {
    kind: "uups", redeployImplementation: "always",
  })) as string;
  const data = lt.interface.encodeFunctionData("upgradeToAndCall", [newImpl, "0x"]);
  console.log(`New impl    : ${newImpl}`);
  console.log("Executive wallet (MetaMask) sends:");
  console.log(`  to   : ${LANDTITLE_PROXY}`);
  console.log(`  value: 0`);
  console.log(`  data : ${data}`);
  console.log("Then check: impl slot == new impl; revokeTitle present; isWhitelisted(node title key) == true.");
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
