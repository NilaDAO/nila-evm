/**
 * P2 — the union mints her crop share when a leader approves her crop plan (executive decision 21 Oct 2026):
 *  - a leader of the batch's union calls mintForBatchMemberByLeader; the token goes to the title holder;
 *  - she is joined to the batch on the way; every other mint check is unchanged;
 *  - nobody else may call it; the upgrade from P1 keeps the storage layout.
 */
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const TITLE = 13;
const Z1 = 1n << 2n;

describe("P2 — leader mints her crop share", function () {
  let ft, lt, roles, owner, oracle, union, farmer, leader, stranger, now;

  beforeEach(async () => {
    [owner, oracle, union, farmer, leader, stranger] = await ethers.getSigners();
    lt = await (await ethers.getContractFactory("MockLandTitleLite")).deploy();
    await lt.set(TITLE, farmer.address, ethers.id("record"));
    roles = await (await ethers.getContractFactory("MockRoles")).deploy();
    await roles.setLeader(union.address, leader.address, true);
    const F = await ethers.getContractFactory("FoodTokenUpgradeable");
    ft = await upgrades.deployProxy(F, ["ipfs://{id}", owner.address, oracle.address], { kind: "uups" });
    await ft.setLandTitleContract(await lt.getAddress());
    await ft.setRolesRegistry(await roles.getAddress());
    await ft.connect(union).createBatch(union.address, 5, 0, ethers.ZeroAddress, 0, 0, 0, 0, 0); // batch 1
    now = await time.latest();
  });

  const byLeader = (who, sos, harvest, mask = Z1, u = union.address, batch = 1) =>
    ft.connect(who).mintForBatchMemberByLeader(u, batch, TITLE, harvest, 1000n, mask, 4047, 0, sos);
  const idOf = (sos, mask = Z1) => ft.packTokenId(TITLE, 5000, sos, 4047, mask);

  it("mints to the title holder, joining her to the batch", async () => {
    const s = now + 10 * DAY;
    await expect(byLeader(leader, s, s + 100 * DAY))
      .to.emit(ft, "MemberJoined").withArgs(1, farmer.address, 0, true)
      .and.to.emit(ft, "TokenMinted");
    expect(await ft.balanceOf(farmer.address, await idOf(s))).to.equal(1000n);
    expect(await ft.balanceOf(leader.address, await idOf(s))).to.equal(0n);
    // a second season: she is already a member
    await byLeader(leader, s + 120 * DAY, s + 200 * DAY);
    expect(await ft.balanceOf(farmer.address, await idOf(s + 120 * DAY))).to.equal(1000n);
  });

  it("a standing batch (no union) takes leaders of a union the owner enabled", async () => {
    await ft.setCropType(8, "maize", []);
    const standing = await ft.canonicalBatch(8);
    const s = now + 10 * DAY;
    await expect(byLeader(leader, s, s + 100 * DAY, Z1, union.address, standing)).to.be.revertedWithCustomError(ft, "NotLeaderOfBatch");
    await expect(ft.connect(leader).setLeaderMintUnion(union.address, true)).to.be.reverted;
    await expect(ft.setLeaderMintUnion(union.address, true)).to.emit(ft, "LeaderMintUnionSet");
    await expect(byLeader(leader, s, s + 100 * DAY, Z1, union.address, standing)).to.emit(ft, "CropShareMintedByLeader");
    expect(await ft.balanceOf(farmer.address, await ft.packTokenId(TITLE, 8000, s, 4047, Z1))).to.equal(1000n);
    // a leader of another union cannot use this union's name
    await expect(byLeader(stranger, s + 200 * DAY, s + 300 * DAY, Z1, union.address, standing)).to.be.revertedWithCustomError(ft, "NotAuthorized");
  });

  it("only a leader of the batch's union (or the union, or the owner) may call it", async () => {
    const s = now + 10 * DAY;
    await expect(byLeader(stranger, s, s + 100 * DAY, Z1, stranger.address)).to.be.revertedWithCustomError(ft, "NotLeaderOfBatch");
    await expect(byLeader(stranger, s, s + 100 * DAY)).to.be.revertedWithCustomError(ft, "NotAuthorized");
    await expect(byLeader(farmer, s, s + 100 * DAY)).to.be.revertedWithCustomError(ft, "NotAuthorized");
    await roles.setLeader(union.address, leader.address, false);
    await expect(byLeader(leader, s, s + 100 * DAY)).to.be.revertedWithCustomError(ft, "NotAuthorized");
    await byLeader(union, s, s + 100 * DAY);
  });

  it("keeps every other check: field claims, SOS window, oracle record", async () => {
    const s = now + 10 * DAY;
    await byLeader(leader, s, s + 100 * DAY);
    await expect(byLeader(leader, s + 50 * DAY, s + 150 * DAY)).to.be.revertedWithCustomError(ft, "FieldAlreadyClaimed");
    await expect(byLeader(leader, now + 400 * DAY, now + 500 * DAY, 1n << 3n)).to.be.revertedWithCustomError(ft, "SosTooFar");
    await lt.set(TITLE, farmer.address, ethers.ZeroHash);
    await expect(byLeader(leader, s, s + 100 * DAY, 1n << 3n)).to.be.revertedWithCustomError(ft, "NoOracleRecord");
  });

  it("her own mint still works and still needs her to hold the title", async () => {
    const s = now + 10 * DAY;
    await ft.connect(farmer).joinBatch(1);
    await ft.connect(farmer).mintForBatchMember(1, TITLE, s + 100 * DAY, 1000n, Z1, 4047, 0, s);
    await ft.connect(stranger).joinBatch(1);
    await expect(ft.connect(stranger).mintForBatchMember(1, TITLE, s + 100 * DAY, 1000n, 1n << 3n, 4047, 0, s))
      .to.be.revertedWithCustomError(ft, "NotLandOwner");
  });

  it("upgrades in place from P1 with the storage layout kept", async () => {
    const P1 = await ethers.getContractFactory("FoodTokenUpgradeableP1");
    const old = await upgrades.deployProxy(P1, ["ipfs://{id}", owner.address, oracle.address], { kind: "uups" });
    const up = await upgrades.upgradeProxy(await old.getAddress(), await ethers.getContractFactory("FoodTokenUpgradeable"));
    expect(await up.owner()).to.equal(owner.address);
  });
});
