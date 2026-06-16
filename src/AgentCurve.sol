// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AgentTreasury} from "./AgentTreasury.sol";

contract AgentCurve is ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;

    string public constant VERSION = "1.0.0";

    uint256 private constant USDC_TO_AGENT_SCALE = 1e12;
    uint256 private constant ONE = 1e18;

    uint256 private constant BPS_DENOM = 10000;

    /// Caps the per-launch premium add-on at 5× (premium = ONE + EXTRA_PREMIUM).
    /// Past PREMIUM_CAP_SUPPLY a buyer mints 1/(1 + EXTRA_PREMIUM/ONE) of the
    /// NAV-pro-rata amount, so this floors a post-cap buyer at ≥1/5 of pro-rata.
    /// A higher ceiling (the old 100e18 → 101×) let a launch be configured so
    /// buyers recover almost nothing — economically confiscatory.
    uint256 private constant MAX_EXTRA_PREMIUM = 4e18;

    AgentTreasury public immutable TREASURY;
    IERC20 public immutable USDC;

    uint256 public immutable PREMIUM_CAP_SUPPLY;
    uint256 public immutable EXTRA_PREMIUM;

    event Bought(
        address indexed buyer, address indexed recipient, uint256 usdcIn, uint256 agentOut, uint256 supplyAfter
    );
    event Sold(address indexed seller, address indexed recipient, uint256 agentIn, uint256 supplyAfter);

    error ZeroAmount();
    error InvalidAddress();
    error SlippageExceeded();
    error NoSupply();
    error NoNav();
    error ZeroAgentOut();
    error DeadlineExpired();
    error ExtraPremiumTooHigh(uint256 given, uint256 max);

    constructor(
        string memory name_,
        string memory symbol_,
        address treasury_,
        address usdc_,
        uint256 premiumCapSupply_,
        uint256 extraPremium_,
        uint256 usdcSeed,
        address seeder,
        address recipient
    ) ERC20(name_, symbol_) {
        if (treasury_ == address(0)) revert InvalidAddress();
        if (usdc_ == address(0)) revert InvalidAddress();
        if (seeder == address(0) || recipient == address(0)) revert InvalidAddress();
        if (premiumCapSupply_ == 0) revert ZeroAmount();
        if (usdcSeed == 0) revert ZeroAmount();
        if (extraPremium_ > MAX_EXTRA_PREMIUM) revert ExtraPremiumTooHigh(extraPremium_, MAX_EXTRA_PREMIUM);

        TREASURY = AgentTreasury(treasury_);
        USDC = IERC20(usdc_);
        PREMIUM_CAP_SUPPLY = premiumCapSupply_;
        EXTRA_PREMIUM = extraPremium_;

        uint256 agentOut = usdcSeed * USDC_TO_AGENT_SCALE;
        _mint(recipient, agentOut);
        emit Bought(seeder, recipient, usdcSeed, agentOut, agentOut);
    }

    function buy(
        uint256 usdcIn,
        uint256 minAgentOut,
        uint256[] calldata minLtOuts,
        address recipient,
        uint256 deadline
    )
        external
        nonReentrant
        returns (uint256 agentOut)
    {
        if (usdcIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidAddress();
        // EIP-2612-style deadline
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert DeadlineExpired();

        USDC.safeTransferFrom(msg.sender, address(this), usdcIn);

        uint256 fee = (usdcIn * TREASURY.feeBps()) / BPS_DENOM;
        uint256 netUsdc = usdcIn - fee;

        uint256 supplyBefore = totalSupply();
        uint256 navBefore = TREASURY.nav();
        agentOut = _quoteBuy(netUsdc, supplyBefore, navBefore);
        if (agentOut < minAgentOut) revert SlippageExceeded();
        if (agentOut == 0) revert ZeroAgentOut();

        if (fee > 0) USDC.safeTransfer(TREASURY.feeRecipient(), fee);

        USDC.forceApprove(address(TREASURY), netUsdc);
        TREASURY.deployUsdc(netUsdc, minLtOuts);

        _mint(recipient, agentOut);
        emit Bought(msg.sender, recipient, usdcIn, agentOut, totalSupply());
    }

    function sell(uint256 agentIn, address recipient, uint256 minUsdcOut, bool returnLts, uint256 deadline)
        external
        nonReentrant
    {
        if (agentIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidAddress();
        // EIP-2612-style deadline
        // slither-disable-next-line timestamp
        if (block.timestamp > deadline) revert DeadlineExpired();

        uint256 supplyBefore = totalSupply();
        if (supplyBefore == 0) revert NoSupply();

        _burn(msg.sender, agentIn);

        TREASURY.withdrawLtsTo(recipient, agentIn, supplyBefore, minUsdcOut, returnLts);

        emit Sold(msg.sender, recipient, agentIn, totalSupply());
    }

    function premium(uint256 supply) public view returns (uint256) {
        if (supply >= PREMIUM_CAP_SUPPLY) {
            return ONE + EXTRA_PREMIUM;
        }
        // slither-disable-next-line divide-before-multiply
        uint256 ratio = (supply * ONE) / PREMIUM_CAP_SUPPLY;
        // slither-disable-next-line divide-before-multiply
        uint256 ratioSq = (ratio * ratio) / ONE;
        return ONE + (ratioSq * EXTRA_PREMIUM) / ONE;
    }

    function quoteBuy(uint256 usdcIn) external view returns (uint256) {
        uint256 netUsdc = usdcIn - (usdcIn * TREASURY.feeBps()) / BPS_DENOM;
        return _quoteBuy(netUsdc, totalSupply(), TREASURY.nav());
    }

    function quoteSellNotional(uint256 agentIn) external view returns (uint256) {
        uint256 s = totalSupply();
        if (s == 0) return 0;
        uint256 navNow = TREASURY.nav();
        uint256 gross = (navNow * agentIn) / s;
        return gross - (gross * TREASURY.feeBps()) / BPS_DENOM;
    }

    function quoteSellUsdc(uint256 agentIn) external view returns (uint256) {
        return TREASURY.quoteWithdrawUsdc(agentIn, totalSupply());
    }

    function _quoteBuy(uint256 usdcIn, uint256 supplyBefore, uint256 navBefore) internal view returns (uint256) {
        if (supplyBefore == 0) {
            return usdcIn * USDC_TO_AGENT_SCALE;
        }
        if (navBefore == 0) revert NoNav();

        uint256 p = premium(supplyBefore);
        return (usdcIn * supplyBefore * ONE) / (navBefore * p);
    }
}
