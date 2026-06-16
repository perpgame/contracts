// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal mock of Bounce's `LeveragedTokenHelper`. Implements just the view
/// AgentTreasury uses: `getLeveragedTokenBufferAssetValue(lt)` — net atomic
/// redeem capacity per LT after subtracting pending credit obligations.
///
/// Buffer values are 18-dec WAD, matching the real helper
/// (`baseAssetBalance().scaleFrom(6) - credit·exchangeRate`). The treasury
/// scales its 6-dec `expectedBaseOut` up by 1e12 before comparing, so a buffer
/// of `N * 1e18` represents ~$N of atomic-redeem capacity.
///
/// Test setup pattern:
/// 1. Deploy MockLeveragedTokenHelper.
/// 2. Set buffer per LT via `setBuffer(lt, value)`. Default is type(int256).max
///    (effectively infinite — every shrink will choose atomic).
/// 3. To force the async path, call `setBuffer(lt, 0)` (or any WAD value below
///    the expected shrink amount * 1e18).
contract MockLeveragedTokenHelper {
    /// Buffer override per LT, in 18-dec WAD. If unset, returns
    /// `type(int256).max` so atomic redeem is always chosen.
    mapping(address => int256) public bufferOverride;
    mapping(address => bool) public overrideSet;

    function setBuffer(address lt, int256 value) external {
        bufferOverride[lt] = value;
        overrideSet[lt] = true;
    }

    function getLeveragedTokenBufferAssetValue(address lt) external view returns (int256) {
        if (overrideSet[lt]) return bufferOverride[lt];
        return type(int256).max;
    }
}
