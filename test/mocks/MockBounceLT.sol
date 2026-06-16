// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockBounceGlobalStorage {
    uint256 public minTransactionSize;

    function setMinTransactionSize(uint256 size) external {
        minTransactionSize = size;
    }
}

/// Minimal mock that implements the IBounceLT surface AgentTreasury depends on.
/// Constant exchange rate (settable per-test). Behaves as a 1:1-NAV vault over USDC.
contract MockBounceLT is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable base;
    MockBounceGlobalStorage public immutable globalStorage;
    string private _targetAsset;
    uint256 private _targetLeverage;
    bool private _isLong;
    /// exchangeRate is USDC-per-LT in 1e18 scale. e.g. 1e18 means 1 LT == 1 USDC.
    uint256 public exchangeRate;
    bool public mintPaused;
    /// When true, redeem() reverts — simulating a delisted LT (e.g. after
    /// Factory::redeployLt) that the treasury can no longer drain through Bounce.
    bool public redeemReverts;
    /// When true, the pricing views revert — faithfully modeling a HyperCore
    /// delisting where ltToBaseAmount's underlying spotBalance precompile errors
    /// (the precompile "consumes all gas", but a plain revert is a conservative
    /// stand-in). userCredit/balanceOf stay readable, as on the real LT.
    bool public ltViewReverts;
    /// Redemption fee in bps applied on redeem(); 0 by default.
    uint256 public redemptionFeeBps;
    /// Mirrors Bounce LT's userCredit storage. prepareRedeem only increments
    /// this — no token movement until a keeper calls executeRedemptions.
    mapping(address => uint256) public userCredit;

    constructor(
        string memory n,
        string memory s,
        address base_,
        string memory targetAsset_,
        uint256 targetLeverage_,
        bool isLong_,
        uint256 exchangeRate_
    ) ERC20(n, s) {
        base = IERC20(base_);
        globalStorage = new MockBounceGlobalStorage();
        _targetAsset = targetAsset_;
        _targetLeverage = targetLeverage_;
        _isLong = isLong_;
        exchangeRate = exchangeRate_;
    }

    // ─── test hooks ──────────────────────────────────────────────────────────

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function setMintPaused(bool paused) external {
        mintPaused = paused;
    }

    function setRedeemReverts(bool reverts) external {
        redeemReverts = reverts;
    }

    function setLtViewReverts(bool reverts) external {
        ltViewReverts = reverts;
    }

    /// Redemption fee in bps (default 0 → fee-free, preserving existing tests).
    /// Mirrors Bounce: redeem returns proceeds NET of redemptionFee × leverage.
    function setRedemptionFeeBps(uint256 bps) external {
        redemptionFeeBps = bps;
    }

    function setMinTransactionSize(uint256 size) external {
        globalStorage.setMinTransactionSize(size);
    }

    // ─── IBounceLT surface ───────────────────────────────────────────────────

    function targetAsset() external view returns (string memory) {
        return _targetAsset;
    }

    function targetLeverage() external view returns (uint256) {
        return _targetLeverage;
    }

    function isLong() external view returns (bool) {
        return _isLong;
    }

    function baseToLtAmount(uint256 baseAmount) public view returns (uint256) {
        // baseAmount in USDC 6dec → LT in 18dec at exchangeRate (USDC-per-LT in 1e18).
        // ltAmount = baseAmount * 1e18 / exchangeRate, with a 1e12 scale to align decimals.
        return (baseAmount * 1e12 * 1e18) / exchangeRate;
    }

    function ltToBaseAmount(uint256 ltAmount) public view returns (uint256) {
        require(!ltViewReverts, "delisted-view");
        // Reverse: ltAmount * exchangeRate / 1e18, then descale 1e12 back to USDC 6dec.
        return (ltAmount * exchangeRate) / (1e18 * 1e12);
    }

    function totalAssets() external view returns (uint256) {
        return base.balanceOf(address(this));
    }

    function mint(address to, uint256 baseAmount, uint256 minOut) external returns (uint256) {
        require(!mintPaused, "paused");
        require(baseAmount >= globalStorage.minTransactionSize(), "BelowMinTransactionSize");
        base.safeTransferFrom(msg.sender, address(this), baseAmount);
        uint256 ltOut = baseToLtAmount(baseAmount);
        require(ltOut >= minOut, "minOut");
        _mint(to, ltOut);
        return ltOut;
    }

    function redeem(address to, uint256 ltAmount, uint256 minBaseAmount) external returns (uint256) {
        require(!redeemReverts, "delisted");
        uint256 grossOut = ltToBaseAmount(ltAmount);
        require(grossOut >= globalStorage.minTransactionSize(), "BelowMinTransactionSize");
        // Mirror real Bounce LT: atomic redeem caps at idle USDC buffer (gross),
        // and proceeds are paid NET of the redemption fee (which stays in the LT).
        require(grossOut <= base.balanceOf(address(this)), "InsufficientBalance");
        uint256 netOut = grossOut - (grossOut * redemptionFeeBps) / 10000;
        require(netOut >= minBaseAmount, "minBaseAmount");
        _burn(msg.sender, ltAmount);
        base.safeTransfer(to, netOut);
        return netOut;
    }

    /// Mirrors Bounce: escrow the LT into this contract and record the credit.
    /// No USDC moves until a keeper executes the redemption.
    function prepareRedeem(uint256 ltAmount) external {
        require(ltAmount > 0, "amount");
        require(ltToBaseAmount(ltAmount) >= globalStorage.minTransactionSize(), "BelowMinTransactionSize");
        _transfer(msg.sender, address(this), ltAmount);
        userCredit[msg.sender] += ltAmount;
    }

    /// Mirrors Bounce cancelRedeem: clears the pending credit (and on-chain
    /// returns the escrowed LT). This mock's prepareRedeem doesn't move the LT,
    /// so the balance already sits with the holder; we only zero the credit.
    function cancelRedeem() external {
        require(userCredit[msg.sender] != 0, "NotRedeeming");
        userCredit[msg.sender] = 0;
    }

    /// Test-only keeper hook simulating Bounce's automation layer executing a
    /// prepared redemption: consumes the credit, burns the escrowed LT, and
    /// transfers USDC to the redeeming user.
    function executeRedemptions(address user, uint256 ltAmount) external {
        require(userCredit[user] >= ltAmount, "credit");
        userCredit[user] -= ltAmount;
        _burn(address(this), ltAmount); // burn from escrow, not the user
        uint256 baseOut = ltToBaseAmount(ltAmount);
        base.safeTransfer(user, baseOut);
    }
}
