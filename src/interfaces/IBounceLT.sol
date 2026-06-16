// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBounceGlobalStorage {
    function minTransactionSize() external view returns (uint256);
}

/// Minimal subset of Bounce Tech's `ILeveragedToken` that AgentTreasury depends
/// on. Full interface lives in github.com/bounce-tech/bounce-smart-contracts.
/// Inherits IERC20 since Bounce LTs are themselves ERC-20s.
interface IBounceLT is IERC20 {
    function mint(address to, uint256 baseAmount, uint256 minOut) external returns (uint256);
    function redeem(address to, uint256 ltAmount, uint256 minBaseAmount) external returns (uint256);
    function prepareRedeem(uint256 ltAmount) external;
    function cancelRedeem() external;
    function userCredit(address user) external view returns (uint256);

    function exchangeRate() external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function baseToLtAmount(uint256 baseAmount) external view returns (uint256);
    function ltToBaseAmount(uint256 ltAmount) external view returns (uint256);
    function mintPaused() external view returns (bool);
    function targetAsset() external view returns (string memory);
    function targetLeverage() external view returns (uint256);
    function isLong() external view returns (bool);
}
