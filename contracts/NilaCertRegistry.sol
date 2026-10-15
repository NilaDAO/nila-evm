// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

interface INilaCert {
    function balanceOf(address farmer) external view returns (uint256);
    function certOf(address farmer) external view returns (
        uint64 issuedAt,
        uint64 expiresAt,
        bool   revoked,
        bool   active
    );
}

/**
 * @title NilaCertRegistry
 * @notice Maps cert index (0–4) to deployed NilaCert contract addresses.
 *         Used by FoodTokenUpgradeable to validate farmer cert status on
 *         joinBatch and refreshCertStatus.
 *
 *         Cert indices:
 *           0 = Fair Trade
 *           1 = Origin (GI/PDO)
 *           2 = Regenerative
 *           3 = Organic
 *           4 = Quality & Safety
 */
contract NilaCertRegistry is Ownable {

    INilaCert[5] public certs;

    string[5] public certNames;

    constructor(address admin) Ownable(admin) {
        certNames[0] = "Fair Trade";
        certNames[1] = "Origin";
        certNames[2] = "Regenerative";
        certNames[3] = "Organic";
        certNames[4] = "Quality & Safety";
    }

    function setCert(uint8 index, address certAddr) external onlyOwner {
        require(index < 5, "Invalid cert index");
        certs[index] = INilaCert(certAddr);
    }

    /**
     * @notice Check which required certs a farmer holds.
     * @param farmer       Farmer wallet.
     * @param requiredMask Bitmask of required cert indices (from batch.requiredCerts).
     * @return held     Bitmask of certs the farmer currently holds (valid + not expired).
     * @return missing  Bitmask of required certs the farmer does NOT hold.
     * @return ok       True if all required certs are held.
     */
    function checkCerts(
        address farmer,
        uint8 requiredMask
    ) external view returns (uint8 held, uint8 missing, bool ok) {
        for (uint8 i = 0; i < 5; i++) {
            if (address(certs[i]) != address(0) && certs[i].balanceOf(farmer) > 0) {
                held |= uint8(1 << i);
            }
        }
        missing = requiredMask & ~held;
        ok = (missing == 0);
    }

    /**
     * @notice Detailed cert status for a farmer — used by the frontend join-batch panel.
     * @return active    Whether each cert is currently valid.
     * @return expiresAt Unix expiry timestamp per cert (0 if not issued).
     */
    function certStatusOf(address farmer) external view returns (
        bool[5] memory active,
        uint64[5] memory expiresAt
    ) {
        for (uint8 i = 0; i < 5; i++) {
            if (address(certs[i]) != address(0)) {
                (, uint64 exp, , bool act) = certs[i].certOf(farmer);
                active[i]    = act;
                expiresAt[i] = exp;
            }
        }
    }
}
