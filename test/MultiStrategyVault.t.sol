// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockERC4626} from "../src/MockERC4626.sol";
import {MockLockedStrategy} from "../src/MockLockedStrategy.sol";
import {MultiStrategyVault} from "../src/MultiStrategyVault.sol";

contract MultiStrategyVaultTest is Test {
    MockUSDC private usdc;
    MockERC4626 private strategyA;
    MockLockedStrategy private strategyB;
    MultiStrategyVault private vault;

    address private user = address(0xBEEF);

    function setUp() public {
        usdc = new MockUSDC();
        strategyA = new MockERC4626(usdc, "Mock A", "mA");
        strategyB = new MockLockedStrategy(usdc, 7 days);
        vault = new MultiStrategyVault(usdc);

        MultiStrategyVault.StrategyConfig[] memory configs = new MultiStrategyVault.StrategyConfig[](2);
        configs[0] =
            MultiStrategyVault.StrategyConfig({strategy: address(strategyA), targetBps: 6_000, isLocked: false});
        configs[1] = MultiStrategyVault.StrategyConfig({strategy: address(strategyB), targetBps: 4_000, isLocked: true});
        vault.setAllocations(configs);
    }

    function testDepositYieldAndWithdrawalQueue() public {
        usdc.mint(user, 1_000e6);

        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        vault.rebalance();

        // Simulate 10% yield on Protocol A (600 -> 660)
        usdc.mint(address(strategyA), 60e6);

        uint256 shares = vault.balanceOf(user);
        uint256 assets = vault.convertToAssets(shares);
        assertApproxEqAbs(assets, 1_060e6, 2);

        vm.startPrank(user);
        uint256 requestId = vault.requestWithdraw(shares);
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(user), 660e6, 2);
        assertEq(vault.pendingAssets(user), 400e6);

        vm.warp(block.timestamp + strategyB.LOCKUP_DURATION() + 1);

        vm.startPrank(user);
        vault.claimWithdraw(requestId);
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(user), 1_060e6, 2);
    }

    function testAllocationCap() public {
        MultiStrategyVault.StrategyConfig[] memory configs = new MultiStrategyVault.StrategyConfig[](1);
        configs[0] =
            MultiStrategyVault.StrategyConfig({strategy: address(strategyA), targetBps: 7_000, isLocked: false});

        vm.expectRevert("CAP_EXCEEDED");
        vault.setAllocations(configs);
    }
}
