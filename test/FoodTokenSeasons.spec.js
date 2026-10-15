/**
 * P1 — FoodToken for 3-season crop plans (15 Oct 2026):
 *  - a mint may carry a future SOS (up to MAX_SOS_AHEAD);
 *  - a field holds one crop at a time: free again from the holding token's harvest date;
 *  - legacy tokens are claimed once by syncFieldClaims;
 *  - the union sells part of its open batch, token by token (sellFromBatch);
 *  - the upgrade keeps the storage layout.
 */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const TITLE = 13;
const Z1 = 1n << 2n; // zone z1 → bit 2
const Z2 = 1n << 3n;

describe("P1 — FoodToken seasons and sales", function () {
  let ft, lt, owner, oracle, union, farmer, buyer, now;

  beforeEach(async () => {
    [owner, oracle, union, farmer, buyer] = await ethers.getSigners();
    lt = await (await ethers.getContractFactory("MockLandTitleLite")).deploy();
    await lt.set(TITLE, farmer.address, ethers.id("record"));
    const F = await ethers.getContractFactory("FoodTokenUpgradeable");
    ft = await upgrades.deployProxy(F, ["ipfs://{id}", owner.address, oracle.address], { kind: "uups" });
    await ft.setLandTitleContract(await lt.getAddress());
    await ft.connect(union).createBatch(union.address, 5, 0, ethers.ZeroAddress, 0, 0, 0, 0, 0); // batch 1: open maize
    await ft.connect(farmer).joinBatch(1);
    now = await time.latest();
  });

  const mint = (sos, harvest, mask = Z1, qty = 1000n, batch = 1) =>
    ft.connect(farmer).mintForBatchMember(batch, TITLE, harvest, qty, mask, 4047, 0, sos);
  const idOf = (sos, mask = Z1) => ft.packTokenId(TITLE, 5000, sos, 4047, mask);

  it("mints all three seasons of a plan at acceptance, future SOS included", async () => {
    const s1 = now + 15 * DAY, s2 = s1 + 150 * DAY, s3 = s2 + 95 * DAY;
    await mint(s1, s1 + 140 * DAY);
    await mint(s2, s2 + 90 * DAY);   // same zone, same calendar year as s3
    await mint(s3, s3 + 90 * DAY);
    expect(await ft.balanceOf(farmer.address, await idOf(s3))).to.equal(1000n);
    expect(await ft.fieldBusyUntil(TITLE, 2)).to.equal(s3 + 90 * DAY);
  });

  it("refuses overlapping seasons on a field and a SOS too far ahead", async () => {
    const s1 = now + 10 * DAY;
    await mint(s1, s1 + 120 * DAY);
    await expect(mint(s1 + 60 * DAY, s1 + 200 * DAY)).to.be.revertedWithCustomError(ft, "FieldAlreadyClaimed");
    await mint(s1 + 60 * DAY, s1 + 200 * DAY, Z2); // another zone is free
    await expect(mint(s1 + 60 * DAY, s1 + 200 * DAY, 1n)).to.be.revertedWithCustomError(ft, "FieldAlreadyClaimed");
    await expect(mint(now + 400 * DAY, now + 500 * DAY, Z2)).to.be.revertedWithCustomError(ft, "SosTooFar");
  });

  it("the live app's mint without a usable harvest date works and holds the field until the oracle reports", async () => {
    const s = now + 3 * DAY;
    await mint(s, 0, Z1);                       // harvestTs 0, as the live PWA sends
    const HELD = 2n ** 32n - 1n;
    expect(await ft.fieldBusyUntil(TITLE, 2)).to.equal(HELD);
    await expect(mint(s + 300 * DAY, s + 400 * DAY, Z1))
      .to.be.revertedWithCustomError(ft, "FieldAlreadyClaimed");   // no time-based release
    await mint(s, s - DAY, Z2);                 // a harvest date before the SOS: same
    expect(await ft.fieldBusyUntil(TITLE, 3)).to.equal(HELD);
    // The oracle later sets the real harvest: the field frees from that date.
    await ft.connect(oracle).updateTokenHarvest(await idOf(s, Z1), s + 100 * DAY);
    expect(await ft.fieldBusyUntil(TITLE, 2)).to.equal(s + 100 * DAY);
  });

  it("a burned token's later date changes move no field", async () => {
    const s = now + 3 * DAY;
    await mint(s, s + 100 * DAY, Z1);
    await ft.connect(oracle).burnToken(await idOf(s, Z1));
    await mint(s + 10 * DAY, s + 100 * DAY, Z1);  // same harvest day as the burned one
    await ft.connect(oracle).updateTokenHarvest(await idOf(s, Z1), s + 20 * DAY);
    expect(await ft.fieldBusyUntil(TITLE, 2)).to.equal(s + 100 * DAY);
  });

  it("an entire-property token blocks every zone until its harvest", async () => {
    const s = now + 5 * DAY;
    await mint(s, s + 100 * DAY, 1n);
    await expect(mint(s + 50 * DAY, s + 150 * DAY, Z1)).to.be.revertedWithCustomError(ft, "EntirePropertyClaimed");
    await mint(s + 100 * DAY, s + 200 * DAY, Z1);
  });

  it("burning or an earlier harvest frees the field; a later token keeps it", async () => {
    const s1 = now + 10 * DAY, h1 = s1 + 120 * DAY;
    await mint(s1, h1);
    await ft.connect(farmer).burnOwnToken(await idOf(s1));
    await mint(s1 + DAY, h1);                       // re-mint after a burn
    await ft.connect(oracle).updateTokenHarvest(await idOf(s1 + DAY), s1 + 90 * DAY);
    await mint(s1 + 90 * DAY, s1 + 200 * DAY);      // free from the new harvest date
    await ft.connect(oracle).updateTokenHarvest(await idOf(s1 + DAY), s1 + 80 * DAY);
    expect(await ft.fieldBusyUntil(TITLE, 2)).to.equal(s1 + 200 * DAY);
  });

  it("a past SOS has no age limit (long crops such as sugarcane)", async () => {
    await time.increase(30 * DAY);
    await mint(now, now + 120 * DAY);
    await mint(now - 400 * DAY, now + 30 * DAY, Z2);
  });

  it("syncFieldClaims claims fields of legacy tokens, oracle or owner only", async () => {
    const s = now + 10 * DAY;
    await mint(s, s + 120 * DAY);
    await ft.connect(oracle).updateTokenHarvest(await idOf(s), s + 120 * DAY);
    await expect(ft.connect(farmer).syncFieldClaims([await idOf(s)])).to.be.revertedWithCustomError(ft, "NotOracle");
    await ft.connect(oracle).syncFieldClaims([await idOf(s), 12345n]);
    expect(await ft.fieldBusyUntil(TITLE, 2)).to.equal(s + 120 * DAY);
  });

  it("sells part of an open batch token by token; the rest stays open", async () => {
    const s = now + 10 * DAY;
    await mint(s, s + 120 * DAY, Z1, 700n);
    await mint(s, s + 120 * DAY, Z2, 300n);
    const a = await idOf(s, Z1), b = await idOf(s, Z2);
    expect((await ft.getBatch(1)).claimedQtyKg).to.equal(1000n);

    await expect(ft.connect(buyer).sellFromBatch(1, buyer.address, s + 200 * DAY, 5n, [a]))
      .to.be.revertedWithCustomError(ft, "NotAuthorized");
    await expect(ft.connect(union).sellFromBatch(1, buyer.address, s + 200 * DAY, 5n, [a]))
      .to.emit(ft, "TokensSold").withArgs(1, 2, [a], 700n);

    expect(await ft.tokenBatch(a)).to.equal(2n);
    expect(await ft.tokenBatch(b)).to.equal(1n);
    expect(await ft.tokenStatus(a)).to.equal(1n);            // the token itself is unchanged
    const sold = await ft.getBatch(2), open = await ft.getBatch(1);
    expect(sold.buyer).to.equal(buyer.address);
    expect(sold.claimedQtyKg).to.equal(700n);
    expect(sold.status).to.equal(1n);
    expect(open.claimedQtyKg).to.equal(300n);
    expect(open.buyer).to.equal(ethers.ZeroAddress);

    // a token already sold, or a sold batch as source, is refused
    await expect(ft.connect(union).sellFromBatch(1, buyer.address, 0, 5n, [a]))
      .to.be.revertedWithCustomError(ft, "TokenNotInBatch");
    await expect(ft.connect(union).sellFromBatch(2, buyer.address, 0, 5n, [a]))
      .to.be.revertedWithCustomError(ft, "NotStanding");
    // the harvest adjusts the sold batch's tally, not the open one
    await ft.connect(oracle).confirmHarvest(a, 0, 800n);
    expect((await ft.getBatch(2)).claimedQtyKg).to.equal(800n);
    expect((await ft.getBatch(1)).claimedQtyKg).to.equal(300n);
  });

  it("upgrades in place from the pre-P1 contract; legacy tokens are then claimed", async () => {
    const V0 = await ethers.getContractFactory("FoodTokenUpgradeableV0");
    const old = await upgrades.deployProxy(V0, ["ipfs://{id}", owner.address, oracle.address], { kind: "uups" });
    await old.setLandTitleContract(await lt.getAddress());
    await old.connect(union).createBatch(union.address, 5, 0, ethers.ZeroAddress, 0, 0, 0, 0, 0);
    await old.connect(farmer).joinBatch(1);
    await time.increase(20 * DAY);
    const s = now + 10 * DAY; // past now: the old rule needs SOS <= now
    await old.connect(farmer).mintForBatchMember(1, TITLE, s + 120 * DAY, 900n, Z1, 4047, 0, s);
    const id = await old.packTokenId(TITLE, 5000, s, 4047, Z1);

    const up = await upgrades.upgradeProxy(await old.getAddress(),
      await ethers.getContractFactory("FoodTokenUpgradeable"), { kind: "uups" });
    expect(await up.balanceOf(farmer.address, id)).to.equal(900n);
    expect(await up.tokenBatch(id)).to.equal(1n);
    expect(await up.tokenHarvestTs(id)).to.equal(s + 120 * DAY);
    expect((await up.getBatch(1)).claimedQtyKg).to.equal(900n);
    // Before the sync the legacy token's field looks free; after it, it is held.
    expect(await up.fieldBusyUntil(TITLE, 2)).to.equal(0n);
    await up.connect(oracle).syncFieldClaims([id]);
    await expect(up.connect(farmer).mintForBatchMember(1, TITLE, s + 200 * DAY, 1n, Z1, 4047, 0, s + 60 * DAY))
      .to.be.revertedWithCustomError(up, "FieldAlreadyClaimed");
    await up.connect(farmer).mintForBatchMember(1, TITLE, s + 300 * DAY, 1n, Z1, 4047, 0, s + 120 * DAY);
  });
});
