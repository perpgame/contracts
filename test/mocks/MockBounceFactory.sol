// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {MockBounceGlobalStorage} from "./MockBounceLT.sol";

/// Test-side Bounce factory. Holds a mutable list of approved LT addresses;
/// AgentTreasury queries `ltExists()` when registering new symbols. Mirrors the
/// real Factory, which backs both `lts()` (array) and `ltExists()` (O(1) map)
/// from the same storage.
contract MockBounceFactory {
    address[] private _lts;
    mapping(address => bool) private _ltExists;
    MockBounceGlobalStorage public immutable globalStorage;

    constructor() {
        globalStorage = new MockBounceGlobalStorage();
        globalStorage.setMinTransactionSize(10e6);
    }

    function lts() external view returns (address[] memory) {
        return _lts;
    }

    function ltExists(address lt) external view returns (bool) {
        return _ltExists[lt];
    }

    function setMinTransactionSize(uint256 size) external {
        globalStorage.setMinTransactionSize(size);
    }

    function add(address lt) external {
        _lts.push(lt);
        _ltExists[lt] = true;
    }

    function addBatch(address[] calldata lts_) external {
        for (uint256 i = 0; i < lts_.length; i++) {
            _lts.push(lts_[i]);
            _ltExists[lts_[i]] = true;
        }
    }

    function remove(uint256 index) external {
        require(index < _lts.length, "oob");
        address removed = _lts[index];
        _lts[index] = _lts[_lts.length - 1];
        _lts.pop();
        _ltExists[removed] = false;
    }
}
