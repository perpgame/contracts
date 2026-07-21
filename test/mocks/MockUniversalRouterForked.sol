// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalRouterForked} from "../../src/interfaces/IUniversalRouterForked.sol";
import {IPermit2} from "../../src/interfaces/IPermit2.sol";
import {IEquityRegistry} from "../../src/interfaces/IEquityRegistry.sol";
import {V4PoolKey} from "../../src/libraries/V4PoolKey.sol";
import {V4SwapEncoder} from "../../src/libraries/V4SwapEncoder.sol";

/// Forked-UniversalRouter stand-in that DECODES the exact hand-encoded calldata
/// {V4SwapEncoder} produces and asserts every structural assumption:
///   - commands == 0x10 (V4_SWAP), single input;
///   - actions == [0x06, 0x0c, 0x0f] (SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
///   - the swap params decode against the CONFIRMED struct layout, i.e.
///     `minHopPriceX36` sits between `amountOutMinimum` and `hookData`;
///   - SETTLE_ALL / TAKE_ALL param tuples match the swap's in/out + amounts;
///   - input is pulled via Permit2 (proving the treasury wired funding right).
///
/// Economics mirror MockSwapRouter: value-conserving at the registry's
/// Chainlink mark (`valueOf`/`amountOf`), with an optional `feeBps` to model
/// pool fee + impact and revert switches to model dead pools. Pays tokenOut
/// from its own balance — tests pre-fund it.
contract MockUniversalRouterForked is IUniversalRouterForked {
    using SafeERC20 for IERC20;

    address public immutable PERMIT2;
    address public immutable STABLE;
    IEquityRegistry public registry;

    uint256 public feeBps; // applied to amountOut; 0 = exact conversion
    bool public revertAll;
    mapping(address => bool) public revertToken;

    // Last-decoded values, exposed so tests can assert the wire format directly.
    bool public lastMinHopWasZero;
    uint128 public lastAmountIn;
    uint128 public lastAmountOutMinimum;
    bool public lastZeroForOne;

    constructor(address permit2_, address stable_, address registry_) {
        PERMIT2 = permit2_;
        STABLE = stable_;
        registry = IEquityRegistry(registry_);
    }

    function setRegistry(address r) external {
        registry = IEquityRegistry(r);
    }

    function setFeeBps(uint256 b) external {
        feeBps = b;
    }

    function setRevertAll(bool r) external {
        revertAll = r;
    }

    function setRevertToken(address token, bool r) external {
        revertToken[token] = r;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        require(block.timestamp <= deadline, "router: expired");
        require(commands.length == 1 && commands[0] == bytes1(0x10), "router: not V4_SWAP");
        require(inputs.length == 1, "router: bad inputs len");

        (bytes memory actions, bytes[] memory params) = abi.decode(inputs[0], (bytes, bytes[]));
        require(actions.length == 3, "router: bad actions len");
        require(
            actions[0] == bytes1(0x06) && actions[1] == bytes1(0x0c) && actions[2] == bytes1(0x0f),
            "router: bad action bytes"
        );
        require(params.length == 3, "router: bad params len");

        // Decode against the CONFIRMED struct layout (minHopPriceX36 before hookData).
        V4SwapEncoder.ExactInputSingleParams memory p =
            abi.decode(params[0], (V4SwapEncoder.ExactInputSingleParams));
        (address settleCurrency, uint256 settleAmount) = abi.decode(params[1], (address, uint256));
        (address takeCurrency, uint256 takeMinOut) = abi.decode(params[2], (address, uint256));

        lastMinHopWasZero = p.minHopPriceX36 == 0;
        lastAmountIn = p.amountIn;
        lastAmountOutMinimum = p.amountOutMinimum;
        lastZeroForOne = p.zeroForOne;

        // in/out currencies follow from direction + the sorted pool key.
        address tokenIn = p.zeroForOne ? p.poolKey.currency0 : p.poolKey.currency1;
        address tokenOut = p.zeroForOne ? p.poolKey.currency1 : p.poolKey.currency0;
        require(settleCurrency == tokenIn, "router: settle != tokenIn");
        require(takeCurrency == tokenOut, "router: take != tokenOut");
        require(settleAmount == p.amountIn, "router: settle amount mismatch");
        require(takeMinOut == p.amountOutMinimum, "router: take min mismatch");

        address stock = tokenIn == STABLE ? tokenOut : tokenIn;
        require(!revertAll, "router dead");
        require(!revertToken[stock], "pool dead");

        // Pull input via Permit2 (msg.sender is the treasury).
        IPermit2(PERMIT2).transferFrom(msg.sender, address(this), p.amountIn, tokenIn);

        // Price at the Chainlink mark when available (value-conserving for the
        // fresh-path tests); fall back to the v4 SPOT mark when Chainlink is
        // stale (weekend), so an execution-priced rebalance/redeem still fills —
        // this is what a real pool does (it never consults Chainlink).
        uint256 amountOut =
            tokenIn == STABLE ? _outStableForStock(stock, p.amountIn) : _outStockForStable(stock, p.amountIn);
        amountOut -= (amountOut * feeBps) / 10000;

        require(amountOut >= p.amountOutMinimum, "router: too little out");
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }

    // stable → stock
    function _outStableForStock(address stock, uint256 amountIn) internal view returns (uint256) {
        try registry.amountOf(stock, amountIn) returns (uint256 o) {
            return o;
        } catch {
            uint256 unit = registry.spotValueOf(stock, 1e18); // USDG per 1e18 stock
            return unit == 0 ? 0 : (amountIn * 1e18) / unit;
        }
    }

    // stock → stable
    function _outStockForStable(address stock, uint256 amountIn) internal view returns (uint256) {
        try registry.valueOf(stock, amountIn) returns (uint256 o) {
            return o;
        } catch {
            return registry.spotValueOf(stock, amountIn);
        }
    }
}
