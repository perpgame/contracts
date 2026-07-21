// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {V4PoolKey} from "./V4PoolKey.sol";

/// @title V4SwapEncoder
/// @notice Hand-encodes calldata for a single exact-input swap through the
/// MODIFIED UniversalRouter fork on Robinhood Chain
/// (0x8876789976dEcBfCbBbe364623C63652db8C0904).
///
/// VERIFIED against the on-chain source (robinhoodchain.blockscout.com, solc
/// 0.8.26) and the Bags "Trade Tokens" guide (docs.bags.fm/robinhood):
///   command byte 0x10 (V4_SWAP)
///   input = abi.encode(bytes actions, bytes[] params)
///     actions = [0x06 SWAP_EXACT_IN_SINGLE, 0x0c SETTLE_ALL, 0x0f TAKE_ALL]
///     params[0] = abi.encode(ExactInputSingleParams)
///     params[1] = abi.encode(address inputCurrency, uint256 amountIn)      // SETTLE_ALL
///     params[2] = abi.encode(address outputCurrency, uint256 minAmountOut) // TAKE_ALL
///
/// The fork adds a Robinhood-specific `minHopPriceX36` field to the swap params.
/// CONFIRMED position: it is the 5th field, BETWEEN `amountOutMinimum` and
/// `hookData` (NOT appended last). We pass 0 to DISABLE the router's per-hop
/// price floor: {EquityTreasury} already enforces its own realized-output floor
/// via `amountOutMinimum` plus a balance-delta check, so the extra router-side
/// floor is redundant and would only add a second, harder-to-reason-about gate.
library V4SwapEncoder {
    // UniversalRouter command byte.
    bytes1 internal constant CMD_V4_SWAP = 0x10;

    // v4 router action bytes (verified on-chain).
    bytes1 internal constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    bytes1 internal constant ACTION_SETTLE_ALL = 0x0c;
    bytes1 internal constant ACTION_TAKE_ALL = 0x0f;

    /// @dev Fork's exact-in single-swap params. Field order is the CONFIRMED
    /// on-chain layout: `minHopPriceX36` sits between `amountOutMinimum` and
    /// `hookData`.
    struct ExactInputSingleParams {
        V4PoolKey.PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36; // ← FORK-ADDED (Robinhood). 0 = floor disabled.
        bytes hookData;
    }

    /// @notice Build (commands, inputs) for one exact-in single-hop swap.
    /// @param key            The pool to trade through (currencies sorted).
    /// @param zeroForOne     Direction: true = currency0 → currency1.
    /// @param inputCurrency  The currency being spent (for SETTLE_ALL).
    /// @param outputCurrency The currency being received (for TAKE_ALL).
    /// @param amountIn       Exact input amount.
    /// @param minAmountOut   Slippage floor on output.
    /// @param minHopPriceX36 Fork-specific per-hop price floor (0 = disabled).
    /// @return commands One-byte command string (V4_SWAP).
    /// @return inputs   Index-aligned input blobs.
    function encodeExactInSingle(
        V4PoolKey.PoolKey memory key,
        bool zeroForOne,
        address inputCurrency,
        address outputCurrency,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 minHopPriceX36
    ) internal pure returns (bytes memory commands, bytes[] memory inputs) {
        commands = abi.encodePacked(CMD_V4_SWAP);

        bytes memory actions =
            abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                minHopPriceX36: minHopPriceX36,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(inputCurrency, uint256(amountIn));
        params[2] = abi.encode(outputCurrency, uint256(minAmountOut));

        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }
}
