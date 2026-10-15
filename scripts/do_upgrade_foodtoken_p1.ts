// Upgrade FoodTokenUpgradeable — P1 (15 Oct 2026): future SOS, field claims per season,
// sellFromBatch, syncFieldClaims. Appends two mappings; no reinitializer.
// Order (reviewer 15 Oct): PAUSE → upgrade → read every TokenMinted → syncFieldClaims in
// chunks → verify a sample → UNPAUSE. While paused no one can mint over a legacy token's
// field (the upgrade drops the calendar-year check before the claims are synced).
// If a step fails, the contract stays paused: fix and re-run (sync is idempotent).
//
// There is no time-based release (executive decision, 15 Oct): a token without a harvest
// date holds its fields until the oracle reports the harvest. So BEFORE this script the
// oracle writes the harvest dates of past tokens from the property records
// (nila-sensing scripts/foodtoken_harvest_backfill.py → updateTokenHarvest, which the
// live contract already has). The script lists active tokens still without one and
// refuses to run while any remain, unless ALLOW_HELD=1.
//
// Run (Ledger owner): npx hardhat run scripts/TOMAINNET/do_upgrade_foodtoken_p1.ts --network polygon-ledger
// Dry run (validate only, no tx): DRY_RUN=1 npx hardhat run ... --network polygon

const { ethers, upgrades } = require("hardhat");

const FOODTOKEN_PROXY = "0x27D83C98666AD0e5dA79e5FEE24133557Bd8D2e8";
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";
const CHUNK = 40;

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
  console.log("validateUpgrade ✅ (two mappings appended)");

  // 0. Tokens that would hold their fields until reported (no harvest date yet).
  const all = await ft.queryFilter(ft.filters.TokenMinted(), 0, "latest");
  const held: string[] = [];
  for (const id of [...new Set(all.map((e: any) => e.args.tokenId.toString()))]) {
    const t = BigInt(id as string);
    const st = Number(await ft.tokenStatus(t));
    if (st === 0 || st === 4) continue;
    if (Number(await ft.tokenHarvestTs(t)) <= Number((t >> 172n) & 0xffffffffn)) held.push(id as string);
  }
  console.log(`Active tokens without a harvest date: ${held.length}`);
  held.slice(0, 50).forEach((id) => console.log(`  held until reported: ${id}`));
  if (held.length && process.env.ALLOW_HELD !== "1") {
    throw new Error("run the oracle harvest backfill first (or ALLOW_HELD=1 to hold these fields)");
  }

  if (process.env.DRY_RUN === "1") {
    const n = (await ft.queryFilter(ft.filters.TokenMinted(), 0, "latest")).length;
    console.log(`DRY_RUN: ${n} TokenMinted events would be synced; no tx sent.`);
    return;
  }

  // 1. Pause: no mint between the upgrade and the synced claims.
  if (!(await ft.paused())) {
    await (await ft.connect(owner).pause()).wait();
  }
  console.log("paused ✅");

  // 2. Upgrade.
  await upgrades.upgradeProxy(FOODTOKEN_PROXY, F, { kind: "uups", redeployImplementation: "always" });
  console.log(`Impl AFTER (chain): ${await implOf(FOODTOKEN_PROXY)}`);

  // 3. Every token ever minted, read AFTER the pause, so none is missed.
  const minted = await ft.queryFilter(ft.filters.TokenMinted(), 0, "latest");
  const ids = [...new Set(minted.map((e: any) => e.args.tokenId.toString()))];
  console.log(`Tokens ever minted: ${ids.length}`);

  // 4. Claim their fields (idempotent; burned tokens are skipped by the contract).
  for (let i = 0; i < ids.length; i += CHUNK) {
    const tx = await ft.connect(owner).syncFieldClaims(ids.slice(i, i + CHUNK));
    await tx.wait();
    console.log(`syncFieldClaims ${i}–${Math.min(i + CHUNK, ids.length)}: ${tx.hash}`);
  }

  // 5. Verify: every live token's fields are held at least until its claim date.
  let bad = 0;
  for (const id of ids) {
    const t = BigInt(id);
    const st = Number(await ft.tokenStatus(t));
    if (st === 0 || st === 4) continue;
    const title = Number(t >> 224n);
    const mask = (t >> 20n) & ((1n << 128n) - 1n);
    const sos = Number((t >> 172n) & 0xffffffffn);
    for (let b = 0; b < 128; b++) {
      if (((mask >> BigInt(b)) & 1n) === 1n && Number(await ft.fieldBusyUntil(title, b)) <= sos) bad++;
      // (held tokens show 4294967295 = held until the oracle reports)
    }
  }
  if (bad) throw new Error(`${bad} field claims not synced — contract left PAUSED`);
  console.log("claims verified ✅");

  // 6. Unpause.
  await (await ft.connect(owner).unpause()).wait();
  console.log("unpaused ✅ — the app may mint new seasons.");
}

main().catch((e) => { console.error(e); process.exit(1); });
