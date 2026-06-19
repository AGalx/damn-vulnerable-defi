# Manual fuzzing notes

This source is isolated from the Damn Vulnerable DeFi challenges to show advanced manual fuzzing work.

`RewardVault.t.sol` uses a custom handler, bounded actions and ghost accounting to reveal and confirm a bug hypothesis: `claimReward()` transfers ETH out but never decreases `rewardPool`, so the vault's real ETH balance becomes desynchronized from its internal accounting.

## Files

- `../../src/manual-fuzzing/WETH.sol`: minimal WETH-style contract kept as a standalone training target.
- `../../src/manual-fuzzing/RewardVault.sol`: intentionally vulnerable reward vault used by the fuzzing scenario.
- `RewardVault.t.sol`: manual invariant test that confirms the accounting bug.

## Run

```sh
forge test --match-contract RewardVaultInvariantTest
```
