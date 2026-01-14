// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {MockERC4626} from "../src/MockERC4626.sol";
import {MockLockedStrategy} from "../src/MockLockedStrategy.sol";
import {MultiStrategyVault} from "../src/MultiStrategyVault.sol";

contract Demo is Script {
    function run() external {
        address user = address(0xBEEF);

        MockUSDC usdc = new MockUSDC();
        MockERC4626 strategyA = new MockERC4626(usdc, "Mock A", "mA");
        MockLockedStrategy strategyB = new MockLockedStrategy(usdc, 7 days);
        MultiStrategyVault vault = new MultiStrategyVault(usdc);

        MultiStrategyVault.StrategyConfig[] memory configs = new MultiStrategyVault.StrategyConfig[](2);
        configs[0] =
            MultiStrategyVault.StrategyConfig({strategy: address(strategyA), targetBps: 6_000, isLocked: false});
        configs[1] = MultiStrategyVault.StrategyConfig({strategy: address(strategyB), targetBps: 4_000, isLocked: true});
        vault.setAllocations(configs);

        usdc.mint(user, 1_000e6);
        console2.log("User USDC before deposit:", usdc.balanceOf(user));

        vm.startPrank(user);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, user);
        vm.stopPrank();

        console2.log("User shares after deposit:", vault.balanceOf(user));

        vault.rebalance();
        console2.log("StrategyA assets after rebalance:", strategyA.totalAssets());
        console2.log("StrategyB assets after rebalance:", strategyB.totalAssets());

        // Simulate 10% yield on StrategyA (600 -> 660).
        usdc.mint(address(strategyA), 60e6);
        console2.log("StrategyA assets after yield:", strategyA.totalAssets());

        uint256 shares = vault.balanceOf(user);
        uint256 assets = vault.convertToAssets(shares);
        console2.log("User assets after yield:", assets);

        vm.startPrank(user);
        uint256 requestId = vault.requestWithdraw(shares);
        vm.stopPrank();

        console2.log("Request ID:", requestId);
        console2.log("User USDC after request:", usdc.balanceOf(user));
        console2.log("User pending assets:", vault.pendingAssets(user));

        vm.warp(block.timestamp + strategyB.LOCKUP_DURATION() + 1);

        vm.startPrank(user);
        vault.claimWithdraw(requestId);
        vm.stopPrank();

        console2.log("User USDC after claim:", usdc.balanceOf(user));
    }
}
