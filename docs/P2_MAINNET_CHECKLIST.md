# FoodToken P2 — the union mints her crop share (mainnet checklist)

Executive decision, 21 Oct 2026: when a leader approves her crop plan (L12), the union mints her FoodTokens; they go
to her wallet (the land title's holder). FoodTokens stay on Polygon; the attester copies them to Stellar (F2).

**Not run.** Claude Code built and tested this on the local fork only. Mainnet needs an executive go and the Ledger.

## What changes
- `mintForBatchMemberByLeader(union, batchId, landTitleId, harvestDate, quantity, fieldsBitmask, areaM2, variety, sos)`:
  caller must be a leader of `union` (RolesRegistry), the union itself or the owner; the batch is the union's own
  (`union_ == union`) or a standing batch (`union_ == 0`) of a union enabled by the owner. The token is minted to
  `ownerOf(landTitleId)`; she is joined to the batch if she is not a member (same cert check as `joinBatch`). Every
  check of `mintForBatchMember` is unchanged (oracle record, field claims per season, SOS window, batch state).
- `setLeaderMintUnion(union, on)` (owner) and event `LeaderMintUnionSet`; event `CropShareMintedByLeader`.
- Storage: one mapping appended (`leaderMintUnions`). Her own `mintForBatchMember` still works.

## Steps
1. `npx hardhat test` (16 passing at `t1/contracts/P2-leader-mint`), and an external review of the diff.
2. Dry run: `DRY_RUN=1 npx hardhat run scripts/do_upgrade_foodtoken_p2.ts --network polygon` — validateUpgrade only.
3. Executive go, then with the Ledger: `LEADER_MINT_UNION=<today's union> npx hardhat run scripts/do_upgrade_foodtoken_p2.ts --network polygon-ledger`.
4. Check: `leaderMintUnions(<union>) == true`; impl slot changed; a leader's mint on a test title (or the first real
   approval) lands in the member's wallet and the attester's F2 follower attests it on Stellar.
5. Ship together: nila-sensing (mint list / gas for the approving leader) and nila-pwa (L12 mints, CP12 waits).
