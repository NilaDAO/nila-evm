// Register the crop families on the mainnet FoodToken (setCropType, owner only). Each call also makes the family's
// standing open batch (canonicalBatch), which the P2 leader mint and the node's mint list use. Families already
// registered with the same name are skipped; a code holding another name stops the run.
//
// The Stellar crop calendar (nila-soroban checklist C16) reads these families: nila-sensing scripts/crop_calendar.py
// lists one window set per family registered here. Run this after the P2 upgrade, before the Stellar deploy.
//
// MAINNET ONLY WITH AN EXECUTIVE GO. One Ledger prompt per family (Ethereum app, blind signing on).
// Dry run (reads only, no tx):  DRY_RUN=1 npx hardhat run scripts/register_crop_types.js --network polygon
// Run (Ledger owner):           npx hardhat run scripts/register_crop_types.js --network polygon-ledger
//
// Codes: families 0–13 as nila-sensing compute/phenology/predict/corrections.py and nila-pwa CROP_CODE_COLOR_KEY
// (mainnet batch 1 = paddy 0, batch 2 = sugarcane 2 already use them); 14–18 as the demo (fodder, green manures).
// Names = the catalogue's chain_name (nila-sensing plan/mint.py), lower case.

const { ethers } = require("hardhat");

const FOODTOKEN_PROXY = "0x27D83C98666AD0e5dA79e5FEE24133557Bd8D2e8";
const FAMILIES = {
  paddy: 0, groundnut: 1, sugarcane: 2, banana: 3, sesame: 6, cassava: 7, maize: 8, green_gram: 9,
  horse_gram: 10, black_gram: 11, fodder_sorghum: 14, cumbu_napier: 15, sunhemp: 16, dhaincha: 17, wild_indigo: 18,
};

async function main() {
  const dry = process.env.DRY_RUN === "1";
  const ft = await ethers.getContractAt("FoodTokenUpgradeable", FOODTOKEN_PROXY);
  const owner = await ft.owner();
  console.log(`FoodToken owner: ${owner}`);
  let signer = null;
  if (!dry) {
    [signer] = await ethers.getSigners();
    if ((await signer.getAddress()).toLowerCase() !== owner.toLowerCase()) {
      throw new Error(`Signer ${await signer.getAddress()} is NOT the FoodToken owner ${owner}`);
    }
  }
  const todo = [];
  for (const [name, code] of Object.entries(FAMILIES)) {
    const have = (await ft.cropName(code)).trim().toLowerCase();
    const batch = await ft.canonicalBatch(code);
    if (have && have !== name) throw new Error(`code ${code} is already "${have}", not ${name}: stop`);
    if (have === name && batch !== 0n) { console.log(`  ${code} ${name}: registered (batch ${batch})`); continue; }
    todo.push([name, code]);
    console.log(`  ${code} ${name}: to register`);
  }
  if (dry || !todo.length) { console.log(dry ? `DRY_RUN: ${todo.length} to register, no tx sent.` : "nothing to do"); return; }
  for (const [name, code] of todo) {
    console.log(`setCropType(${code}, "${name}", []) — approve on the Ledger`);
    await (await ft.connect(signer).setCropType(code, name, [])).wait();
    console.log(`  ✅ ${code} ${name}: batch ${await ft.canonicalBatch(code)}`);
  }
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
