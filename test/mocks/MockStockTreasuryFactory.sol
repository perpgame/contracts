// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal stand-in for TreasuryFactory, exposing the views AgentTreasury reads:
/// the global pause flag, the protocol fee config, and the infra addresses
/// consumed by initialize (STABLE / SWAP_ROUTER / REGISTRY). Treasuries require
/// a non-zero factory at initialize, so tests point at this. All mutable fields
/// are settable to exercise pause and fee-redirect behavior.
contract MockStockTreasuryFactory {
    bool public paused;
    address public feeRecipient = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;
    uint16 public feeBps = 100; // 1%
    /// Default 0 = legacy 100%-to-platform behavior. Tests set this to exercise
    /// the creator/platform split.
    uint16 public creatorFeeShareBps = 0;

    // Sourced by AgentTreasury.initialize, mirroring the real factory immutables.
    address public immutable STABLE;
    address public immutable SWAP_ROUTER;
    address public immutable REGISTRY;

    constructor(address stable_, address swapRouter_, address registry_) {
        STABLE = stable_;
        SWAP_ROUTER = swapRouter_;
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
