/**
 * Title revoke (executive decision 4 Nov 2026): a union leader removes a member, or a member
 * burns her own title; the land title NFT goes to 0x…dEaD and the node attests on Stellar.
 * revokeTitle: whitelisted signer (the node's title key) or owner only; no holder approval.
 * The upgrade appends nothing to storage (checked against the Polygon manifest layout).
 */
const { expect } = require("chai");
const hre = require("hardhat");
const { ethers, upgrades } = hre;
const fs = require("fs");
const path = require("path");
const core = require("@openzeppelin/upgrades-core");
const { readValidations } = require("@openzeppelin/hardhat-upgrades/dist/utils/validations");

const DEAD = "0x000000000000000000000000000000000000dEaD";
const LIVE_IMPL = "0x343A8AAFb6c4a54F0A9AA2Dd8623B26171e333a5"; // NilaLandTitle impl in .openzeppelin/polygon.json

describe("NilaLandTitle — revokeTitle", function () {
  let lt, owner, node, member, other, nonce;

  async function mintTo(to) {
    const meta = `ipfs://record-${nonce}`, name = `title-${nonce++}`;
    const h = ethers.solidityPackedKeccak256(
      ["address", "uint256", "address", "string", "string"],
      [await lt.getAddress(), (await ethers.provider.getNetwork()).chainId, to, meta, name]
    );
    const sig = await node.signMessage(ethers.getBytes(h));
    const rc = await (await lt.mintAndSend(to, meta, name, sig)).wait();
    return rc.logs.map((l) => { try { return lt.interface.parseLog(l); } catch { return null; } })
      .find((e) => e && e.name === "TitleNameSet").args.tokenId;
  }

  beforeEach(async () => {
    [owner, node, member, other] = await ethers.getSigners();
    nonce = 0;
    const F = await ethers.getContractFactory("NilaLandTitle");
    lt = await upgrades.deployProxy(F, [owner.address], { kind: "uups" });
    await lt.addToWhitelist(node.address);
  });

  it("whitelisted node key revokes without the holder; balance and enumeration updated; event", async () => {
    const t1 = await mintTo(member.address);
    const t2 = await mintTo(member.address);
    expect(await lt.balanceOf(member.address)).to.equal(2n);
    await expect(lt.connect(node).revokeTitle(t1))
      .to.emit(lt, "TitleRevoked").withArgs(t1, member.address, node.address)
      .and.to.emit(lt, "Transfer").withArgs(member.address, DEAD, t1);
    expect(await lt.ownerOf(t1)).to.equal(DEAD);
    expect(await lt.balanceOf(member.address)).to.equal(1n);
    expect(await lt.tokenOfOwnerByIndex(member.address, 0)).to.equal(t2);
    await expect(lt.tokenOfOwnerByIndex(member.address, 1)).to.be.reverted;
    expect(await lt.balanceOf(DEAD)).to.equal(1n);
    expect(await lt.tokenOfOwnerByIndex(DEAD, 0)).to.equal(t1);
    expect(await lt.totalSupply()).to.equal(2n);
  });

  it("owner revokes", async () => {
    const t = await mintTo(member.address);
    await expect(lt.connect(owner).revokeTitle(t))
      .to.emit(lt, "TitleRevoked").withArgs(t, member.address, owner.address);
    expect(await lt.ownerOf(t)).to.equal(DEAD);
    expect(await lt.balanceOf(member.address)).to.equal(0n);
  });

  it("anyone else is refused, the holder included; removed whitelist key refused", async () => {
    const t = await mintTo(member.address);
    await expect(lt.connect(other).revokeTitle(t)).to.be.revertedWith("not authorized");
    await expect(lt.connect(member).revokeTitle(t)).to.be.revertedWith("not authorized");
    await lt.removeFromWhitelist(node.address);
    await expect(lt.connect(node).revokeTitle(t)).to.be.revertedWith("not authorized");
    expect(await lt.ownerOf(t)).to.equal(member.address);
  });

  it("double revoke and unknown token refused", async () => {
    const t = await mintTo(member.address);
    await lt.connect(node).revokeTitle(t);
    await expect(lt.connect(node).revokeTitle(t)).to.be.revertedWith("already revoked");
    await expect(lt.connect(node).revokeTitle(999)).to.be.revertedWith("token does not exist");
  });

  it("holder's own transfer to 0x…dEaD still works, and revoke then refuses", async () => {
    const t = await mintTo(member.address);
    await lt.connect(member).transferFrom(member.address, DEAD, t);
    expect(await lt.ownerOf(t)).to.equal(DEAD);
    expect(await lt.balanceOf(member.address)).to.equal(0n);
    await expect(lt.connect(node).revokeTitle(t)).to.be.revertedWith("already revoked");
  });

  it("storage layout is upgrade-safe against the live implementation (Polygon manifest)", async () => {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, "../.openzeppelin/polygon.json"), "utf8"));
    const live = Object.values(manifest.impls).find((i) => i.address === LIVE_IMPL);
    expect(live, "live impl in manifest").to.exist;
    const data = await readValidations(hre);
    const art = await hre.artifacts.readArtifact("NilaLandTitle");
    const version = core.getVersion(art.bytecode, art.deployedBytecode);
    const updated = core.getStorageLayout(data, version);
    const report = core.getStorageUpgradeReport(live.layout, updated, core.withValidationDefaults({}));
    expect(report.ok, report.explain()).to.equal(true);
    core.assertUpgradeSafe(data, version, core.withValidationDefaults({ kind: "uups" }));
  });
});
