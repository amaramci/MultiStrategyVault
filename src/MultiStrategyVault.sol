// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";
import {ERC20} from "./utils/ERC20.sol";
import {AccessControl} from "./utils/AccessControl.sol";
import {Pausable} from "./utils/Pausable.sol";

interface ILockupStrategy {
    function lockupEnd(address owner) external view returns (uint256);
}

contract MultiStrategyVault is ERC20, AccessControl, Pausable {
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_BPS_PER_PROTOCOL = 6_000;

    struct StrategyConfig {
        address strategy;
        uint256 targetBps;
        bool isLocked;
    }

    struct WithdrawalRequest {
        address owner;
        address strategy;
        uint256 strategyShares;
        uint256 assets;
        uint256 readyAt;
        bool claimed;
    }

    IERC20 public immutable assetToken;

    StrategyConfig[] private _strategies;
    mapping(address => bool) public isStrategy;
    mapping(address => uint256) public pendingShares;
    mapping(address => uint256) public pendingAssets;
    mapping(uint256 => WithdrawalRequest) public withdrawalRequests;

    uint256 public nextRequestId = 1;

    event AllocationsSet(address indexed manager);
    event Rebalanced(address indexed manager);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed owner,
        address indexed strategy,
        uint256 assets,
        uint256 shares,
        uint256 readyAt
    );
    event WithdrawalClaimed(uint256 indexed requestId, address indexed owner, uint256 assets);

    constructor(IERC20 asset_) ERC20("Multi Strategy Vault", "MSV", 6) {
        assetToken = asset_;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    function totalAssets() public view returns (uint256) {
        uint256 assets = assetToken.balanceOf(address(this));
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; i++) {
            StrategyConfig memory cfg = _strategies[i];
            uint256 strategyAssets = _strategyAssets(cfg.strategy);
            uint256 reserved = _reservedAssets(cfg.strategy);
            assets += strategyAssets - reserved;
        }
        return assets;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return _convertToShares(assets, totalAssets(), totalSupply);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return _convertToAssets(shares, totalAssets(), totalSupply);
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) external view returns (uint256) {
        return _previewMint(shares, totalAssets(), totalSupply);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return _previewWithdraw(assets, totalAssets(), totalSupply);
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) external whenNotPaused returns (uint256) {
        require(assets > 0, "ZERO_ASSETS");
        uint256 shares = convertToShares(assets);
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER_FAIL");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    function mint(uint256 shares, address receiver) external whenNotPaused returns (uint256) {
        uint256 assets = _previewMint(shares, totalAssets(), totalSupply);
        require(assetToken.transferFrom(msg.sender, address(this), assets), "TRANSFER_FAIL");
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external whenNotPaused returns (uint256) {
        require(assets > 0, "ZERO_ASSETS");
        uint256 shares = previewWithdraw(assets);
        _spendAllowance(owner, shares);
        _burn(owner, shares);
        _withdrawImmediate(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external whenNotPaused returns (uint256) {
        require(shares > 0, "ZERO_SHARES");
        uint256 assets = _convertToAssets(shares, totalAssets(), totalSupply);
        _spendAllowance(owner, shares);
        _burn(owner, shares);
        _withdrawImmediate(assets, receiver);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    function requestWithdraw(uint256 shares) external whenNotPaused returns (uint256 requestId) {
        require(shares > 0, "ZERO_SHARES");
        uint256 totalBefore = totalAssets();
        uint256 supply = totalSupply;
        uint256 assets = _convertToAssets(shares, totalBefore, supply);
        _burn(msg.sender, shares);

        uint256 cashAssets = assetToken.balanceOf(address(this));
        uint256 assetsRemaining = assets;

        uint256 cashPortion = (assets * cashAssets) / totalBefore;
        if (cashPortion > 0) {
            require(assetToken.transfer(msg.sender, cashPortion), "TRANSFER_FAIL");
            assetsRemaining -= cashPortion;
        }

        address firstLocked = address(0);
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; i++) {
            StrategyConfig memory cfg = _strategies[i];
            uint256 available = _strategyAssets(cfg.strategy) - _reservedAssets(cfg.strategy);
            if (available == 0) {
                continue;
            }
            uint256 portion = (assets * available) / totalBefore;
            if (portion == 0) {
                continue;
            }

            if (cfg.isLocked) {
                if (firstLocked == address(0)) {
                    firstLocked = cfg.strategy;
                }
                uint256 strategyShares = IERC4626(cfg.strategy).previewWithdraw(portion);
                pendingShares[cfg.strategy] += strategyShares;
                pendingAssets[msg.sender] += portion;

                uint256 readyAt = _lockupEnd(cfg.strategy);
                requestId = _recordWithdrawal(msg.sender, cfg.strategy, strategyShares, portion, readyAt);
            } else {
                IERC4626(cfg.strategy).withdraw(portion, address(this), address(this));
                require(assetToken.transfer(msg.sender, portion), "TRANSFER_FAIL");
            }
            assetsRemaining -= portion;
        }

        if (assetsRemaining > 0) {
            uint256 cashBalance = assetToken.balanceOf(address(this));
            if (cashBalance >= assetsRemaining) {
                require(assetToken.transfer(msg.sender, assetsRemaining), "TRANSFER_FAIL");
                assetsRemaining = 0;
            } else if (firstLocked != address(0)) {
                uint256 strategyShares = IERC4626(firstLocked).previewWithdraw(assetsRemaining);
                pendingShares[firstLocked] += strategyShares;
                pendingAssets[msg.sender] += assetsRemaining;
                uint256 readyAt = _lockupEnd(firstLocked);
                requestId = _recordWithdrawal(msg.sender, firstLocked, strategyShares, assetsRemaining, readyAt);
                assetsRemaining = 0;
            } else {
                revert("INSUFFICIENT_LIQUIDITY");
            }
        }
    }

    function claimWithdraw(uint256 requestId) external {
        WithdrawalRequest storage request = withdrawalRequests[requestId];
        require(request.owner == msg.sender, "NOT_OWNER");
        require(!request.claimed, "ALREADY_CLAIMED");
        require(block.timestamp >= request.readyAt, "NOT_READY");

        request.claimed = true;
        pendingShares[request.strategy] -= request.strategyShares;
        uint256 assets = IERC4626(request.strategy).redeem(request.strategyShares, msg.sender, address(this));
        if (pendingAssets[msg.sender] >= assets) {
            pendingAssets[msg.sender] -= assets;
        } else {
            pendingAssets[msg.sender] = 0;
        }
        emit WithdrawalClaimed(requestId, msg.sender, assets);
    }

    function setAllocations(StrategyConfig[] calldata configs) external onlyRole(MANAGER_ROLE) {
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; i++) {
            isStrategy[_strategies[i].strategy] = false;
        }
        delete _strategies;

        uint256 totalBps;
        for (uint256 i = 0; i < configs.length; i++) {
            StrategyConfig calldata cfg = configs[i];
            require(cfg.strategy != address(0), "ZERO_STRATEGY");
            require(cfg.targetBps <= MAX_BPS_PER_PROTOCOL, "CAP_EXCEEDED");
            require(IERC4626(cfg.strategy).asset() == address(assetToken), "ASSET_MISMATCH");
            totalBps += cfg.targetBps;
            require(totalBps <= MAX_BPS, "BPS_OVERFLOW");
            _strategies.push(cfg);
            isStrategy[cfg.strategy] = true;
        }

        emit AllocationsSet(msg.sender);
    }

    function rebalance() external onlyRole(MANAGER_ROLE) whenNotPaused {
        uint256 total = totalAssets();
        uint256 cash = assetToken.balanceOf(address(this));
        uint256 length = _strategies.length;

        for (uint256 i = 0; i < length; i++) {
            StrategyConfig memory cfg = _strategies[i];
            uint256 targetAssets = (total * cfg.targetBps) / MAX_BPS;
            uint256 currentAssets = _strategyAssets(cfg.strategy);

            if (currentAssets < targetAssets) {
                uint256 toDeposit = targetAssets - currentAssets;
                if (toDeposit > cash) {
                    toDeposit = cash;
                }
                if (toDeposit > 0) {
                    assetToken.approve(cfg.strategy, toDeposit);
                    IERC4626(cfg.strategy).deposit(toDeposit, address(this));
                    cash -= toDeposit;
                }
            } else if (currentAssets > targetAssets && !cfg.isLocked) {
                uint256 toWithdraw = currentAssets - targetAssets;
                IERC4626(cfg.strategy).withdraw(toWithdraw, address(this), address(this));
                cash += toWithdraw;
            }
        }

        emit Rebalanced(msg.sender);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function strategyCount() external view returns (uint256) {
        return _strategies.length;
    }

    function strategyConfig(uint256 index) external view returns (StrategyConfig memory) {
        return _strategies[index];
    }

    function _recordWithdrawal(
        address owner,
        address strategy,
        uint256 strategyShares,
        uint256 assets,
        uint256 readyAt
    ) internal returns (uint256 requestId) {
        requestId = nextRequestId++;
        withdrawalRequests[requestId] = WithdrawalRequest({
            owner: owner,
            strategy: strategy,
            strategyShares: strategyShares,
            assets: assets,
            readyAt: readyAt,
            claimed: false
        });
        emit WithdrawalRequested(requestId, owner, strategy, assets, strategyShares, readyAt);
    }

    function _withdrawImmediate(uint256 assets, address receiver) internal {
        uint256 liquid = assetToken.balanceOf(address(this));
        uint256 length = _strategies.length;
        for (uint256 i = 0; i < length; i++) {
            StrategyConfig memory cfg = _strategies[i];
            if (cfg.isLocked) {
                continue;
            }
            liquid += _strategyAssets(cfg.strategy) - _reservedAssets(cfg.strategy);
        }
        require(assets <= liquid, "LOCKED_LIQUIDITY");

        uint256 remaining = assets;
        uint256 cashBalance = assetToken.balanceOf(address(this));
        if (cashBalance > 0) {
            uint256 pay = cashBalance >= remaining ? remaining : cashBalance;
            require(assetToken.transfer(receiver, pay), "TRANSFER_FAIL");
            remaining -= pay;
        }

        for (uint256 i = 0; i < length && remaining > 0; i++) {
            StrategyConfig memory cfg = _strategies[i];
            if (cfg.isLocked) {
                continue;
            }
            uint256 available = _strategyAssets(cfg.strategy) - _reservedAssets(cfg.strategy);
            if (available == 0) {
                continue;
            }
            uint256 toWithdraw = remaining > available ? available : remaining;
            IERC4626(cfg.strategy).withdraw(toWithdraw, address(this), address(this));
            require(assetToken.transfer(receiver, toWithdraw), "TRANSFER_FAIL");
            remaining -= toWithdraw;
        }

        require(remaining == 0, "INSUFFICIENT_LIQUIDITY");
    }

    function _strategyAssets(address strategy) internal view returns (uint256) {
        uint256 shares = IERC4626(strategy).balanceOf(address(this));
        if (shares == 0) {
            return 0;
        }
        return IERC4626(strategy).convertToAssets(shares);
    }

    function _reservedAssets(address strategy) internal view returns (uint256) {
        uint256 shares = pendingShares[strategy];
        if (shares == 0) {
            return 0;
        }
        return IERC4626(strategy).convertToAssets(shares);
    }

    function _lockupEnd(address strategy) internal view returns (uint256) {
        return ILockupStrategy(strategy).lockupEnd(address(this));
    }

    function _convertToShares(uint256 assets, uint256 totalAssets_, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) {
            return assets;
        }
        return (assets * supply) / totalAssets_;
    }

    function _convertToAssets(uint256 shares, uint256 totalAssets_, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) {
            return shares;
        }
        return (shares * totalAssets_) / supply;
    }

    function _previewWithdraw(uint256 assets, uint256 totalAssets_, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) {
            return assets;
        }
        return (assets * supply + totalAssets_ - 1) / totalAssets_;
    }

    function _previewMint(uint256 shares, uint256 totalAssets_, uint256 supply) internal pure returns (uint256) {
        if (supply == 0) {
            return shares;
        }
        return (shares * totalAssets_ + supply - 1) / supply;
    }

    function _spendAllowance(address owner, uint256 shares) internal {
        if (owner != msg.sender) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ALLOWANCE");
                allowance[owner][msg.sender] = allowed - shares;
            }
        }
    }
}
