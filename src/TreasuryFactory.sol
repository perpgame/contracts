// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
import {AgentTreasury} from "./AgentTreasury.sol";

contract TreasuryFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDC;
    address public immutable LT_HELPER;
    address public immutable BOUNCE_FACTORY;
    address public immutable TREASURY_BEACON;

    address public feeRecipient;
    uint16 public feeBps;

    uint16 public constant MAX_FEE_BPS = 500;
    address public constant DEFAULT_FEE_RECIPIENT = 0xb2feD3aCf6e30e0f1902A2b190C88C9a0a68eDC3;
    uint16 public constant DEFAULT_FEE_BPS = 100; // 1%

    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct DeployParams {
        address user;
        bytes32 salt;
        uint256 seed;
        /// agentic → platform rebalancer key, classic → the user
        address rebalancer;
        AgentTreasury.AssetSpec[] initialPortfolio;
        string reasoningCid;
        string curveName;
        string curveSymbol;
        uint256 premiumCapSupply;
        uint256 extraPremium;
        uint256[] minLtOuts;
    }

    /// Global emergency stop read by every deployed treasury's deployUsdc /
    /// withdrawLtsTo. Halts buys and sells across all treasuries at once.
    bool public paused;

    event TreasuryDeployed(address indexed user, address indexed treasury, address indexed curve, bytes32 salt);
    event PausedSet(bool paused);
    event FeeRecipientSet(address indexed previous, address indexed next);
    event FeeBpsSet(uint16 previous, uint16 next);

    error InvalidAddress();
    error ZeroSeed();
    error PermitValueTooLow();
    error InsufficientAllowance();
    error AddressMismatch();
    error FeeBpsTooHigh(uint16 given, uint16 max);

    constructor(
        address usdc_,
        address ltHelper_,
        address bounceFactory_,
        address treasuryBeacon_,
        address owner_
    ) Ownable(owner_) {
        if (
            usdc_ == address(0) || ltHelper_ == address(0) || bounceFactory_ == address(0)
                || treasuryBeacon_ == address(0)
        ) {
            revert InvalidAddress();
        }
        USDC = IERC20(usdc_);
        LT_HELPER = ltHelper_;
        BOUNCE_FACTORY = bounceFactory_;
        TREASURY_BEACON = treasuryBeacon_;
        feeRecipient = DEFAULT_FEE_RECIPIENT;
        feeBps = DEFAULT_FEE_BPS;
    }

    function setFeeRecipient(address next) external onlyOwner {
        if (next == address(0)) revert InvalidAddress();
        emit FeeRecipientSet(feeRecipient, next);
        feeRecipient = next;
    }

    function setFeeBps(uint16 next) external onlyOwner {
        if (next > MAX_FEE_BPS) revert FeeBpsTooHigh(next, MAX_FEE_BPS);
        emit FeeBpsSet(feeBps, next);
        feeBps = next;
    }

    /// @notice Deploy a BeaconProxy fronting an AgentTreasury (and its spawned AgentCurve) funded by user permit
    function deployTreasury(DeployParams calldata p, PermitData calldata permit)
        external
        onlyOwner
        nonReentrant
        returns (address treasury, address curve)
    {
        if (p.user == address(0)) revert InvalidAddress();
        if (p.seed == 0) revert ZeroSeed();
        if (permit.value < p.seed) revert PermitValueTooLow();

        // Apply the permit, tolerating front-run grief
        try IERC20Permit(address(USDC)).permit(
            p.user, address(this), permit.value, permit.deadline, permit.v, permit.r, permit.s
        ) {} catch {}
        if (USDC.allowance(p.user, address(this)) < p.seed) revert InsufficientAllowance();

        // slither-disable-next-line arbitrary-send-erc20-permit
        USDC.safeTransferFrom(p.user, address(this), p.seed);

        bytes32 saltFull = _saltFor(p.user, p.salt);
        bytes memory initData = _initData(p);
        bytes memory proxyInitCode = _proxyInitCode(initData);
        address predicted = Create2.computeAddress(saltFull, keccak256(proxyInitCode));
        
        USDC.forceApprove(predicted, p.seed);

        BeaconProxy deployed = new BeaconProxy{salt: saltFull}(TREASURY_BEACON, initData);
        if (address(deployed) != predicted) revert AddressMismatch();

        treasury = address(deployed);
        curve = AgentTreasury(treasury).curve();

        // Zero any residual allowance and refund dust; the factory must never
        // accumulate a balance.
        USDC.forceApprove(predicted, 0);
        uint256 dust = USDC.balanceOf(address(this));
        if (dust > 0) USDC.safeTransfer(p.user, dust);

        emit TreasuryDeployed(p.user, treasury, curve, saltFull);
    }

    function predictTreasury(DeployParams calldata p) external view returns (address) {
        return Create2.computeAddress(_saltFor(p.user, p.salt), keccak256(_proxyInitCode(_initData(p))));
    }

    /// @notice Set the global pause that halts buys and sells across every
    /// treasury deployed by this factory. Owner-only emergency stop.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function rescue(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function _saltFor(address user, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(user, salt));
    }

    function _initData(DeployParams calldata p) internal view returns (bytes memory) {
        return abi.encodeCall(
            AgentTreasury.initialize,
            (
                p.rebalancer,
                p.user,
                address(this),
                p.initialPortfolio,
                p.reasoningCid,
                _curveInit(p)
            )
        );
    }

    function _proxyInitCode(bytes memory initData) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(BeaconProxy).creationCode,
            abi.encode(TREASURY_BEACON, initData)
        );
    }

    function _curveInit(DeployParams calldata p) internal view returns (AgentTreasury.CurveInitParams memory) {
        return AgentTreasury.CurveInitParams({
            name: p.curveName,
            symbol: p.curveSymbol,
            premiumCapSupply: p.premiumCapSupply,
            extraPremium: p.extraPremium,
            usdcSeed: p.seed,
            seeder: address(this),
            recipient: p.user,
            minLtOuts: p.minLtOuts
        });
    }
}
