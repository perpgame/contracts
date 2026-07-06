// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAgentTreasury} from "./interfaces/IAgentTreasury.sol";

/// @title DuelMarket — parimutuel prediction market between two agent treasuries.
/// @notice Trustless resolution: winner = higher treasury PnL% over [lock, expiry],
///         read directly from AgentTreasury.nav(). No oracle.
contract DuelMarket is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status { Open, Locked, Resolved, Voided }

    struct Duel {
        address treasuryA;
        address treasuryB;
        uint64  lockTime;
        uint64  expiryTime;
        uint128 poolA;
        uint128 poolB;
        uint256 navStartA;
        uint256 navStartB;
        uint256 navEndA;
        uint256 navEndB;
        Status  status;
        uint8   winner;          // 0=A, 1=B, 2=tie (meaningful only when Resolved)
        uint16  feeBpsSnapshot;  // fee bps locked in at resolve time; used in claim()
    }

    IERC20 public immutable USDC;

    uint16  public feeBps;
    address public feeRecipient;
    bool    public paused;

    uint16  public constant MAX_FEE_BPS    = 1_000;   // 10%
    uint64  public constant MIN_BET_WINDOW = 1 hours; // lock must be >= now + this
    uint64  public constant MIN_DURATION   = 1 hours; // expiry >= lock + this
    uint64  public constant MAX_DURATION   = 90 days; // expiry <= lock + this
    uint128 public constant MIN_BET        = 1e6;     // 1 USDC

    Duel[] public duels;
    mapping(uint256 => mapping(address => uint128)) public stakeA;
    mapping(uint256 => mapping(address => uint128)) public stakeB;
    mapping(uint256 => mapping(address => bool))    public claimed;

    event DuelCreated(uint256 indexed duelId, address indexed treasuryA, address indexed treasuryB, uint64 lockTime, uint64 expiryTime, address creator);
    event BetPlaced(uint256 indexed duelId, address indexed bettor, uint8 side, uint128 amount);
    event DuelLocked(uint256 indexed duelId, uint256 navStartA, uint256 navStartB);
    event DuelResolved(uint256 indexed duelId, uint8 winner, uint256 navEndA, uint256 navEndB);
    event DuelVoided(uint256 indexed duelId);
    event Claimed(uint256 indexed duelId, address indexed bettor, uint256 payout);
    event FeeConfigChanged(uint16 feeBps, address feeRecipient);
    event PausedSet(bool paused);

    error InvalidTreasury();
    error SameTreasury();
    error BadTiming();
    error NotOpen();
    error BettingClosed();
    error BelowMinBet();
    error BadSide();
    error TooEarly();
    error WrongStatus();
    error AlreadyClaimed();
    error NothingToClaim();
    error IsPaused();
    error FeeTooHigh();

    constructor(address usdc, address feeRecipient_, uint16 feeBps_, address owner_) Ownable(owner_) {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        USDC = IERC20(usdc);
        feeRecipient = feeRecipient_;
        feeBps = feeBps_;
    }

    // --- admin ---
    function setFeeConfig(uint16 feeBps_, address feeRecipient_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh();
        feeBps = feeBps_;
        feeRecipient = feeRecipient_;
        emit FeeConfigChanged(feeBps_, feeRecipient_);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    // --- create ---
    function createDuel(address treasuryA, address treasuryB, uint64 lockTime, uint64 expiryTime)
        external
        returns (uint256 duelId)
    {
        if (paused) revert IsPaused();
        if (treasuryA == treasuryB) revert SameTreasury();
        if (IAgentTreasury(treasuryA).nav() == 0) revert InvalidTreasury();
        if (IAgentTreasury(treasuryB).nav() == 0) revert InvalidTreasury();
        if (lockTime < block.timestamp + MIN_BET_WINDOW) revert BadTiming();
        if (expiryTime < lockTime + MIN_DURATION) revert BadTiming();
        if (expiryTime > lockTime + MAX_DURATION) revert BadTiming();

        duelId = duels.length;
        Duel storage d = duels.push();
        d.treasuryA = treasuryA;
        d.treasuryB = treasuryB;
        d.lockTime = lockTime;
        d.expiryTime = expiryTime;
        d.status = Status.Open;

        emit DuelCreated(duelId, treasuryA, treasuryB, lockTime, expiryTime, msg.sender);
    }

    // --- bet ---

    function bet(uint256 duelId, uint8 side, uint128 amount) public nonReentrant {
        _bet(duelId, side, amount);
    }

    function betWithPermit(
        uint256 duelId,
        uint8 side,
        uint128 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        // Best-effort permit: swallow failure so a front-run of the permit
        // (same owner/spender/nonce) can't DoS the bet — the safeTransferFrom
        // below still enforces allowance.
        try IERC20Permit(address(USDC)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _bet(duelId, side, amount);
    }

    function _bet(uint256 duelId, uint8 side, uint128 amount) internal {
        if (paused) revert IsPaused();
        Duel storage d = duels[duelId];
        if (d.status != Status.Open) revert NotOpen();
        if (block.timestamp >= d.lockTime) revert BettingClosed();
        if (amount < MIN_BET) revert BelowMinBet();
        if (side > 1) revert BadSide();

        USDC.safeTransferFrom(msg.sender, address(this), amount);
        if (side == 0) {
            stakeA[duelId][msg.sender] += amount;
            d.poolA += amount;
        } else {
            stakeB[duelId][msg.sender] += amount;
            d.poolB += amount;
        }
        emit BetPlaced(duelId, msg.sender, side, amount);
    }

    // --- lock ---

    function lock(uint256 duelId) external nonReentrant {
        Duel storage d = duels[duelId];
        if (d.status != Status.Open) revert WrongStatus();
        if (block.timestamp < d.lockTime) revert TooEarly();

        if (d.poolA == 0 || d.poolB == 0) {
            d.status = Status.Voided;
            emit DuelVoided(duelId);
            return;
        }
        uint256 navA = IAgentTreasury(d.treasuryA).nav();
        uint256 navB = IAgentTreasury(d.treasuryB).nav();
        if (navA == 0 || navB == 0) {
            d.status = Status.Voided;
            emit DuelVoided(duelId);
            return;
        }
        d.navStartA = navA;
        d.navStartB = navB;
        d.status = Status.Locked;
        emit DuelLocked(duelId, navA, navB);
    }

    // --- resolve ---

    function resolve(uint256 duelId) external nonReentrant {
        Duel storage d = duels[duelId];
        if (d.status != Status.Locked) revert WrongStatus();
        if (block.timestamp < d.expiryTime) revert TooEarly();

        // F2 fix: if either treasury's nav() reverts (e.g. delisted/paused underlying),
        // void the duel so bettors can reclaim stakes instead of freezing funds forever.
        uint256 navEndA;
        uint256 navEndB;
        try IAgentTreasury(d.treasuryA).nav() returns (uint256 nA) {
            navEndA = nA;
        } catch {
            d.status = Status.Voided;
            emit DuelVoided(duelId);
            return;
        }
        try IAgentTreasury(d.treasuryB).nav() returns (uint256 nB) {
            navEndB = nB;
        } catch {
            d.status = Status.Voided;
            emit DuelVoided(duelId);
            return;
        }

        d.navEndA = navEndA;
        d.navEndB = navEndB;

        // Signed PnL in 1e18 fixed point. navStart is guaranteed > 0 (set in lock()).
        // SafeCast reverts on genuine overflow instead of silently wrapping.
        int256 pnlA = (SafeCast.toInt256(navEndA) - SafeCast.toInt256(d.navStartA)) * 1e18 / SafeCast.toInt256(d.navStartA);
        int256 pnlB = (SafeCast.toInt256(navEndB) - SafeCast.toInt256(d.navStartB)) * 1e18 / SafeCast.toInt256(d.navStartB);

        uint8 winner;
        if (pnlA > pnlB) winner = 0;
        else if (pnlB > pnlA) winner = 1;
        else winner = 2;

        d.winner = winner;
        // F1 fix: snapshot the current feeBps so claim() uses the same rate
        // as the fee transfer below, regardless of future setFeeConfig() calls.
        d.feeBpsSnapshot = feeBps;
        d.status = Status.Resolved;

        if (winner != 2) {
            uint256 loserPool = winner == 0 ? uint256(d.poolB) : uint256(d.poolA);
            uint256 fee = loserPool * feeBps / 10_000;
            if (fee > 0) USDC.safeTransfer(feeRecipient, fee);
        }
        emit DuelResolved(duelId, winner, navEndA, navEndB);
    }

    // --- claim ---

    function claim(uint256 duelId) external nonReentrant {
        Duel storage d = duels[duelId];
        if (d.status != Status.Resolved && d.status != Status.Voided) revert WrongStatus();
        if (claimed[duelId][msg.sender]) revert AlreadyClaimed();

        uint256 payout;
        if (d.status == Status.Voided || d.winner == 2) {
            payout = uint256(stakeA[duelId][msg.sender]) + uint256(stakeB[duelId][msg.sender]);
        } else if (d.winner == 0) {
            uint256 s = stakeA[duelId][msg.sender];
            if (s != 0) {
                uint256 loserPool = uint256(d.poolB);
                // F1 fix: use per-duel snapshot, not the mutable live feeBps
                uint256 fee = loserPool * d.feeBpsSnapshot / 10_000;
                payout = s + (s * (loserPool - fee)) / uint256(d.poolA);
            }
        } else {
            uint256 s = stakeB[duelId][msg.sender];
            if (s != 0) {
                uint256 loserPool = uint256(d.poolA);
                // F1 fix: use per-duel snapshot, not the mutable live feeBps
                uint256 fee = loserPool * d.feeBpsSnapshot / 10_000;
                payout = s + (s * (loserPool - fee)) / uint256(d.poolB);
            }
        }

        if (payout == 0) revert NothingToClaim();
        claimed[duelId][msg.sender] = true;           // effects before interaction
        USDC.safeTransfer(msg.sender, payout);
        emit Claimed(duelId, msg.sender, payout);
    }

    // --- views ---
    function duelCount() external view returns (uint256) {
        return duels.length;
    }

    function getDuel(uint256 duelId) external view returns (Duel memory) {
        return duels[duelId];
    }
}
