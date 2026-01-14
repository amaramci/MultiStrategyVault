// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {MockERC4626} from "./MockERC4626.sol";

contract MockLockedStrategy is MockERC4626 {
    uint256 public immutable lockupDuration;
    mapping(address => uint256) public lastDepositTime;

    constructor(IERC20 asset_, uint256 lockupDuration_)
        MockERC4626(asset_, "Mock Locked Vault", "mLOCK")
    {
        lockupDuration = lockupDuration_;
    }

    function lockupEnd(address owner) external view returns (uint256) {
        return lastDepositTime[owner] + lockupDuration;
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        uint256 shares = super.deposit(assets, receiver);
        lastDepositTime[receiver] = block.timestamp;
        return shares;
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        require(block.timestamp >= lastDepositTime[owner] + lockupDuration, "LOCKED");
        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        require(block.timestamp >= lastDepositTime[owner] + lockupDuration, "LOCKED");
        return super.redeem(shares, receiver, owner);
    }
}
