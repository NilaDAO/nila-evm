# nila-evm

Nila's contracts on Polygon that stay in use while the loans move to Stellar
([nila-soroban](https://github.com/NilaDAO/nila-soroban)).

| Contract | What it does | Polygon mainnet (proxy) |
|---|---|---|
| `FoodTokenUpgradeable` | ERC-1155 crop share ("food token"): one token per field and season of a crop plan; batches and sales | `0x27D83C98666AD0e5dA79e5FEE24133557Bd8D2e8` |
| `NilaLandTitle` | Land-title NFT; a member is whoever holds a title her union minted | `0x636060dbC695a8232992b28c1765828263f17251` |
| `GenericFund1155Module` | Food tokens deposited as junior shares | `0x6DA1D7aA48986245A1D4D287a79E719d5a268787` |
| `NilaCertRegistry` | Farmer certificates checked when joining a batch (FoodToken dependency) | — |

The loans, cash desk, roles and vouchers have moved to Stellar; the earlier Polygon contracts
(fund core, viewer, FX pool, nIN, roles, POL swap) are no longer developed here.

## FoodToken upgrade P1 (not deployed yet)

For 3-season crop plans:

- a mint may carry a future SOS (up to a year ahead), and a past SOS has no age limit;
- a field holds one crop at a time and is free again from the holding token's harvest date;
  a token without a usable harvest date holds it until the oracle reports the harvest
  (`updateTokenHarvest` / `confirmHarvest`); there is no time-based release;
- `sellFromBatch`: the union sells part of its open batch, token by token, into a sold batch;
- `syncFieldClaims`: claims the fields of tokens minted before the upgrade.

`test/FoodTokenSeasons.spec.js` includes an in-place upgrade from the pre-P1 contract
(`contracts/mocks/FoodTokenUpgradeableV0.sol`). The upgrade (`scripts/do_upgrade_foodtoken_p1.ts`)
runs paused: pause → upgrade → sync the field claims → verify → unpause. It is signed by the
owner's Ledger; nothing in this repository holds a key.

```bash
npm ci
npx hardhat test
# upgrade, by the owner only:
POLYGON_RPC_URL=… LEDGER_ACCOUNT=… npx hardhat run scripts/do_upgrade_foodtoken_p1.ts --network polygon-ledger
```

`.openzeppelin/polygon.json` is the upgrades manifest for the deployed proxies (public addresses
and storage layouts).
