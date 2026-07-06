// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Treasury mock with a settable nav and a `reverting` flag.
///      When `reverting` is true, nav() reverts to simulate a paused/delisted treasury.
///      Do NOT modify MockAgentTreasury — 38 existing tests depend on it.
contract MockRevertingTreasury {
    uint256 private _nav;
    bool    public  reverting;

    constructor(uint256 nav_) { _nav = nav_; }

    function nav() external view returns (uint256) {
        require(!reverting, "nav down");
        return _nav;
    }

    function setNav(uint256 n) external { _nav = n; }
    function setReverting(bool r) external { reverting = r; }
}
