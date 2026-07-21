// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";

/// Minimal AllowanceTransfer Permit2 stand-in for equity-treasury tests. Model:
/// `approve` records a (owner→token→spender) allowance; `transferFrom` (called
/// by the router) checks it, decrements it, and moves the token via the ERC-20
/// allowance the owner granted THIS contract. Etch this at the canonical Permit2
/// address (0x0000...78BA3) with vm.etch so `EquityTreasury.PERMIT2` resolves to
/// it. Asserts the two-leg approve flow the real router requires.
contract MockPermit2 is IPermit2 {
    using SafeERC20 for IERC20;

    struct Allowance {
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    // owner => token => spender => allowance
    mapping(address => mapping(address => mapping(address => Allowance))) internal _allow;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        Allowance storage a = _allow[msg.sender][token][spender];
        a.amount = amount;
        a.expiration = expiration;
    }

    function allowance(address owner, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Allowance storage a = _allow[owner][token][spender];
        return (a.amount, a.expiration, a.nonce);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = _allow[from][token][msg.sender];
        require(a.amount >= amount, "Permit2: insufficient allowance");
        require(a.expiration >= block.timestamp, "Permit2: allowance expired");
        if (a.amount != type(uint160).max) a.amount -= amount;
        // Pull via the ERC-20 allowance `from` granted this (Permit2) contract.
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}
