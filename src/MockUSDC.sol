// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "./utils/ERC20.sol";

contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC", 6) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
