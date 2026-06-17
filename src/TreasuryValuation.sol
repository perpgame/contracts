// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBounceLT} from "./interfaces/IBounceLT.sol";

interface ILtHelper {
    function getLeveragedTokenBufferAssetValue(address lt) external view returns (int256);
}

/// Per-symbol asset config. Declared here (not in AgentTreasury) so this
/// library and the contract share one definition without a circular import.
/// Field order/types are the storage layout for `AgentTreasury.assets` — never
/// reorder or retype across upgrades.
struct AssetConfig {
    address lt;
    uint16 targetBps;
    bool registered;
}

/// Read-only valuation helpers extracted from AgentTreasury to keep the
/// implementation under the EIP-170 24,576-byte code limit. Deployed once and
/// DELEGATECALL-linked, so every function runs in the treasury's context:
/// `address(this)` is the treasury and the storage pointers address its slots.
/// Behaviour is byte-for-byte identical to the former in-contract methods.
library TreasuryValuation {
    uint16 private constant BPS_DENOM = 10000;

    /// USDC (6-dec) → 1e18 WAD; the buffer helper returns 18-dec, so the
    /// 6-dec expected base must be scaled up before comparing.
    uint256 private constant USDC_TO_WAD = 1e12;

    function heldLtValues(string[] storage symbols, mapping(string => AssetConfig) storage assets)
        public
        view
        returns (uint256[] memory ltValues, uint256 totalLtValue)
    {
        uint256 n = symbols.length;
        ltValues = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
            uint256 bal = lt.balanceOf(address(this));
            if (bal == 0) continue;
            ltValues[i] = lt.ltToBaseAmount(bal);
            totalLtValue += ltValues[i];
        }
    }

    /// Sum of all LTs held + idle USDC.
    function nav(string[] storage symbols, mapping(string => AssetConfig) storage assets, IERC20 usdc)
        public
        view
        returns (uint256 total)
    {
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
            uint256 bal = lt.balanceOf(address(this));
            if (bal > 0) total += lt.ltToBaseAmount(bal);
        }
        total += usdc.balanceOf(address(this));
    }

    /// nav() plus the value of in-flight (escrowed) redemptions, which
    /// `prepareRedeem` moves out of `balanceOf` while recording `userCredit`.
    function navWithPendingRedemptions(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 usdc
    ) public view returns (uint256 total) {
        uint256 n = symbols.length;
        for (uint256 i = 0; i < n; i++) {
            IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
            uint256 held = lt.balanceOf(address(this)) + lt.userCredit(address(this));
            if (held > 0) total += lt.ltToBaseAmount(held);
        }
        total += usdc.balanceOf(address(this));
    }

    function redeemFitsBuffer(address ltHelper, IBounceLT lt, uint256 expectedBase) public view returns (bool) {
        int256 bufferRaw = ILtHelper(ltHelper).getLeveragedTokenBufferAssetValue(address(lt));
        uint256 buffer = bufferRaw < 0 ? 0 : uint256(bufferRaw);
        return expectedBase * USDC_TO_WAD <= buffer;
    }

    function quoteWithdrawUsdc(
        string[] storage symbols,
        mapping(string => AssetConfig) storage assets,
        IERC20 usdc,
        address ltHelper,
        uint256 agentShares,
        uint256 totalShares,
        uint256 minTx,
        uint16 feeBps
    ) public view returns (uint256) {
        if (agentShares == 0 || totalShares == 0) return 0;

        uint256 n = symbols.length;
        uint256 idle = usdc.balanceOf(address(this));

        (uint256[] memory ltValues, uint256 totalLtValue) = heldLtValues(symbols, assets);

        uint256 notional = ((idle + totalLtValue) * agentShares) / totalShares;
        uint256 idlePaid = (idle * agentShares) / totalShares;
        uint256 remaining = notional - idlePaid;

        uint256 redeemable = 0;
        if (remaining > 0 && totalLtValue > 0) {
            for (uint256 i = 0; i < n; i++) {
                if (ltValues[i] == 0) continue;

                IBounceLT lt = IBounceLT(assets[symbols[i]].lt);
                uint256 ltOut = (lt.balanceOf(address(this)) * remaining) / totalLtValue;
                if (ltOut == 0) continue;

                uint256 expectedBase = lt.ltToBaseAmount(ltOut);
                if (expectedBase < minTx) continue;

                if (redeemFitsBuffer(ltHelper, lt, expectedBase)) redeemable += expectedBase;
            }
        }

        uint256 gross = idlePaid + redeemable;
        return gross - (gross * feeBps) / BPS_DENOM;
    }
}
