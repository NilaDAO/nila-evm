// Upgrade FoodTokenUpgradeable — P2 (21 Oct 2026, executive decision): the union mints her crop share when a leader
// approves her crop plan (mintForBatchMemberByLeader; the token goes to the title holder). Appends one mapping
// (leaderMintUnions); no reinitializer, no field or token migration.
//
// MAINNET ONLY WITH AN EXECUTIVE GO — see docs/P2_MAINNET_CHECKLIST.md. Claude Code never runs this on mainnet.
// Run (Ledger owner): npx hardhat run scripts/do_upgrade_foodtoken_p2.ts --network polygon-ledger
// Dry run (validate only, no tx): DRY_RUN=1 npx hardhat run scripts/do_upgrade_foodtoken_p2.ts --network polygon
// After the upgrade, the owner enables today's union for the standing batches: LEADER_MINT_UNION=0x… (same run).

const { ethers, upgrades } = require("hardhat");

const FOODTOKEN_PROXY = "0x27D83C98666AD0e5dA79e5FEE24133557Bd8D2e8";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

async function implOf(proxy: string): Promise<string> {
  const raw = await ethers.provider.getStorage(proxy, IMPL_SLOT);
  return ethers.getAddress("0x" + raw.slice(26));
}

async function main() {
  const [owner] = await ethers.getSigners();
  const ft = await ethers.getContractAt("FoodTokenUpgradeable", FOODTOKEN_PROXY);
  console.log(`Block  : ${await ethers.provider.getBlockNumber()}`);
  console.log(`Signer : ${await owner.getAddress()}`);
  const proxyOwner = await ft.owner();
  if (proxyOwner.toLowerCase() !== (await owner.getAddress()).toLowerCase()) {
    throw new Error(`Signer is NOT the proxy owner. Owner: ${proxyOwner}`);
  }
  console.log(`Impl BEFORE (chain): ${await implOf(FOODTOKEN_PROXY)}`);
  const F = await ethers.getContractFactory("FoodTokenUpgradeable", owner);
  await upgrades.validateUpgrade(FOODTOKEN_PROXY, F, { kind: "uups" });
  console.log("validateUpgrade ✅ (one mapping appended)");
  if (process.env.DRY_RUN === "1") { console.log("DRY_RUN: no tx sent."); return; }

  await upgrades.upgradeProxy(FOODTOKEN_PROXY, F, { kind: "uups", redeployImplementation: "always" });
  console.log(`Impl AFTER  (chain): ${await implOf(FOODTOKEN_PROXY)}`);
  const union = process.env.LEADER_MINT_UNION;
  if (union) {
    await (await ft.connect(owner).setLeaderMintUnion(union, true)).wait();
    console.log(`leaderMintUnions[${union}] = ${await ft.leaderMintUnions(union)} ✅`);
  }
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
