// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// Minimal stand-in for TreasuryFactory, exposing the views AgentTreasury reads:
/// the global pause flag and the protocol fee config. Treasuries require a
/// non-zero factory at initialize, so tests point at this. All fields are
/// settable to exercise pause and fee-redirect behavior.
contract MockTreasuryFactory {
    bool public paused;
    address public feeRecipient = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;
    uint16 public feeBps = 100; // 1%

    // Sourced by AgentTreasury.initialize, mirroring the real factory immutables.
    address public immutable USDC;
    address public immutable LT_HELPER;
    address public immutable BOUNCE_FACTORY;

    constructor(address usdc_, address ltHelper_, address bounceFactory_) {
        USDC = usdc_;
        LT_HELPER = ltHelper_;
        BOUNCE_FACTORY = bounceFactory_;
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
}
