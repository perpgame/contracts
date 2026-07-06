// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
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
        uint8   winner; // 0=A, 1=B, 2=tie (meaningful only when Resolved)
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

    // --- views ---
    function duelCount() external view returns (uint256) {
        return duels.length;
    }

    function getDuel(uint256 duelId) external view returns (Duel memory) {
        return duels[duelId];
    }
}
