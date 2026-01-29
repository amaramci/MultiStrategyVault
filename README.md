# Multi-Strategy Vault 

An ERC4626-style vault that allocates deposits across multiple strategies, supports locked liquidity, and provides a withdrawal request queue for locked protocols.

## Highlights
- Multi-strategy allocation with target BPS and per-protocol cap.
- Rebalance moves assets to match allocation targets.
- Locked strategies create withdrawal requests that can be claimed after lockup.
- Immediate withdraw/redeem from liquid strategies and vault cash.
- Role-based access control and pausing.

## Contracts
- `src/MultiStrategyVault.sol`: Vault with allocation, rebalance, and withdrawal queue logic.
- `src/MockERC4626.sol`: Simple ERC4626 mock strategy.
- `src/MockLockedStrategy.sol`: ERC4626 strategy with lockup logic.
- `src/MockUSDC.sol`: 6-decimal mock USDC used for tests/demo.

## Repo Layout
- `src/`: Core contracts and mocks.
- `test/`: Foundry tests.
- `script/`: Demo script exercising deposit, rebalance, yield, and withdrawal queue.

## Quick Start
Requires Foundry: https://book.getfoundry.sh/getting-started/installation

```bash
forge build
forge test -vvv
```

## Demo Script
Runs a local in-memory demo (no chain RPC needed).

```bash
forge script script/Demo.s.sol:Demo -vvv
```

## Notes and Assumptions
- `MAX_BPS_PER_PROTOCOL` is 60% to enforce diversification.
- Locked strategies cannot be force-withdrawn during rebalance or immediate withdraws.
- Withdrawal requests track strategy shares and are claimable after lockup.

## Submission Links
- Google Drive (public): <ADD_LINK_HERE>
- Loom Video (public): <ADD_LINK_HERE>

