// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {ERC20} from "./utils/ERC20.sol";

contract MockERC4626 is ERC20, IERC4626 {
    IERC20 public immutable underlying;

    constructor(IERC20 asset_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_, 6)
    {
        underlying = asset_;
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() public view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return assets;
        }
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return shares;
        }
        return (shares * totalAssets()) / supply;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return _previewMint(shares);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return assets;
        }
        return (assets * supply + totalAssets() - 1) / totalAssets();
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256) {
        require(assets > 0, "ZERO_ASSETS");
        uint256 shares = convertToShares(assets);
        require(underlying.transferFrom(msg.sender, address(this), assets), "TRANSFER_FAIL");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) external returns (uint256) {
        uint256 assets = _previewMint(shares);
        require(underlying.transferFrom(msg.sender, address(this), assets), "TRANSFER_FAIL");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) public virtual returns (uint256) {
        uint256 shares = previewWithdraw(assets);
        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ALLOWANCE");
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
        _burn(owner, shares);
        require(underlying.transfer(receiver, assets), "TRANSFER_FAIL");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) public virtual returns (uint256) {
        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ALLOWANCE");
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
        uint256 assets = convertToAssets(shares);
        _burn(owner, shares);
        require(underlying.transfer(receiver, assets), "TRANSFER_FAIL");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function _previewMint(uint256 shares) internal view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) {
            return shares;
        }
        return (shares * totalAssets() + supply - 1) / supply;
    }
}
