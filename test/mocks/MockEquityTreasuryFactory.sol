// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Stand-in for EquityTreasuryFactory, exposing the views EquityTreasury reads
/// at initialize (STABLE / ROUTER / REGISTRY) plus the global pause flag and fee
/// config. Mirrors MockStockTreasuryFactory but exposes `ROUTER()` (the forked
/// v4 UniversalRouter) instead of `SWAP_ROUTER()`.
contract MockEquityTreasuryFactory {
    bool public paused;
    address public feeRecipient = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;
    uint16 public feeBps = 100; // 1%
    /// Default 0 = legacy 100%-to-platform behavior. Tests set this to exercise
    /// the creator/platform split.
    uint16 public creatorFeeShareBps = 0;

    address public immutable STABLE;
    address public immutable ROUTER;
    address public immutable REGISTRY;

    constructor(address stable_, address router_, address registry_) {
        STABLE = stable_;
        ROUTER = router_;
        REGISTRY = registry_;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setFeeRecipient(address r) external {
        feeRecipient = r;
    }

    function setFeeBps(uint16 b) external {
        feeBps = b;
    }

    function setCreatorFeeShareBps(uint16 b) external {
        creatorFeeShareBps = b;
    }
}
