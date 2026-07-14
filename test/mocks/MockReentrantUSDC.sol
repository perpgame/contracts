// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {DuelMarket} from "../../src/DuelMarket.sol";

/// @title MockReentrantUSDC
/// @notice A malicious ERC20 that re-enters DuelMarket.claim() during transfer.
///
/// When the market calls `safeTransfer(victim, payout)`, this token's
/// `_update` hook fires, which triggers the victim's `onReceive` callback.
/// The `ReentrantReceiver` then calls `market.claim(duelId)` again.
///
/// Expected outcome: the reentrant call reverts because either:
///   - The `nonReentrant` guard fires (OZ ReentrancyGuard: ReentrancyGuardReentrantCall), or
///   - The `claimed` flag was already set before `safeTransfer` (checks-effects-interactions),
///     so the guard `AlreadyClaimed` fires.
/// Either way, the initial claim completes normally and the reentrant attempt is blocked.
contract MockReentrantUSDC is ERC20, ERC20Permit {
    // Set before the malicious transfer; the hook calls `receiver.trigger()`
    address public receiver;
    bool    public armed; // only fire the hook once (avoid infinite recursion in setup)

    constructor() ERC20("Reentrant USDC", "rUSDC") ERC20Permit("Reentrant USDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Arm the hook so the *next* transfer to `receiver_` triggers the callback.
    function arm(address receiver_) external {
        receiver = receiver_;
        armed    = true;
    }

    /// @dev Override _update to inject the reentrant call.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && to == receiver) {
            armed = false; // disarm immediately to prevent infinite loop
            IReentrantReceiver(receiver).onReceive();
        }
    }
}

interface IReentrantReceiver {
    function onReceive() external;
}
