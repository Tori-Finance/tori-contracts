# Formal verification (halmos)

The `check_*` functions in this directory are properties proven by [halmos](https://github.com/a16z/halmos)
symbolic execution: for every input within the stated bounds, every path through the code satisfies the
assertion. They are not fuzz tests; a property passes only when no counterexample exists.

CI: `.github/workflows/formal-verification.yml` runs every property on each pull request and push to
main that touches `contracts/`, `test/` or the build configuration, in nine parallel jobs. A
counterexample, a solver TIMEOUT, an internal ERROR, a property whose paths all revert, or any path
dropped at the loop bound fails the job.

Run locally (the same command a CI job runs):

```sh
npm install                                  # OpenZeppelin, Chainlink CCIP, forge-std
python -m pip install halmos==0.3.3
halmos --match-contract '^TrUSDHalmos$'      # one group
halmos                                       # everything matched by halmos.toml
```

Settings live in `halmos.toml`: prefix `check_`, contracts matching `Halmos$`, loop bound 3, 300s per
solver query, the yices solver that ships with the halmos wheel. Do not run a plain `forge build` in the
same checkout right before halmos: artifacts without the AST make halmos skip every contract
(`forge clean` fixes it).

## How the properties are written

- **Arbitrary call.** `_arbitraryCall` (HalmosBase) sends symbolic calldata covering every non-view
  function of the contract, every argument symbolic, from a symbolic or fixed caller; the property then
  asserts on the resulting state. "Only X can change Y" is proven this way.
- **Must revert.** A low-level call followed by `assert(!ok)`. halmos ignores reverting paths, so a bare
  revert proves nothing.
- **Total setup.** Setup steps never revert for any symbolic input (approvals are granted for whoever is
  funded, zero-address cases are branched around): a reverting setup silently drops that part of the
  input space.
- **Branch-free folding.** halmos counts every revisit of a symbolic branch as a loop iteration and drops
  paths past the bound, so per-role checks are folded into bitmasks (`_bit`) and asserted once.
- **Deployment shape.** Upgradeable contracts run behind their ERC1967 proxy, initialized and wired as in
  production (timelock admin bootstrapped, minter set, roles granted).

## Global bounds and exclusions

| Bound | Why |
| --- | --- |
| Symbolic dynamic arrays have length 0, 1 or 2; `bytes`/`string` 0, 65 or 1024 bytes (halmos defaults); loop bound 3 | Makes "every function, every argument" finite. Batch functions are covered up to two elements. |
| Caller `address(0)` excluded from arbitrary calls | No transaction can come from it. Admitting it gives spurious counterexamples (Ownable2Step `acceptOwnership` while `pendingOwner() == address(0)`). |
| The timelock excluded as caller where a property is about everyone else | Its upgrade right can by design replace the logic. That only the timelock can upgrade is proven separately (`check_upgradeToAndCall_onlyTimelock` and equivalents). |
| One call per arbitrary-call property | Multi-step sequences are covered where they matter (two mints in a block, schedule then execute, deposit then harvest). |
| Signatures | halmos models `ecrecover` as an uninterpreted function, so "a signature for A never validates B" needs the ECDSA unforgeability assumption. Binding is proven as: execution requires the sender's approval of exactly `hashOrder(order)`, and `hashOrder` is injective over every field and the chain id. |
| Arithmetic | A symbolic 256-bit multiply-and-divide between two symbolic operands, or OZ `mulDiv` with any symbolic operand, does not close in either bundled solver (yices, z3). Where the arithmetic matters, one operand comes from a documented concrete grid; see each property. |

## Properties

Status: **proven** = holds for all inputs within the global bounds above; **bounded** = proven under the
extra bound named in the row. Every property below was also checked against a deliberately broken copy
of the code (see "Mutation check").

### trUSD (`TrUSDHalmos`)

| Property | What it proves | Status |
| --- | --- | --- |
| `check_mint_onlyMinter` | Any caller other than the minter is refused, for any recipient and amount. | proven |
| `check_totalSupply_onlyMinterIncreases` | No call by anyone but the minter raises total supply. | proven |
| `check_balance_onlyOwnerOrSpenderDecreases` | A balance falls only by the holder's or an allowance holder's call (permit included). | proven |
| `check_transfer_conservesSupply` | transfer moves exactly `amount`, fails only on insufficient balance, supply unchanged. | proven |
| `check_burn_reducesSupplyExactly` | burn reduces supply and balance by exactly the amount. | proven |
| `check_upgradeToAndCall_onlyTimelock` | Upgrading to a real new implementation reverts for every caller but the timelock. | proven |
| `check_upgrade_onlyTimelock` | No call by anyone but the timelock changes the implementation slot. | proven |
| `check_privilegedState_onlyAdminOrTimelock` | Minter, TIMELOCK_ADMIN_ROLE and DEFAULT_ADMIN_ROLE change only by admin or timelock. | proven |
| `check_admin_cannotTouchTimelockRoleOrMinter` | Once bootstrapped, even the admin cannot grant/revoke/re-seat the timelock role or change the minter. | proven |
| `check_renounceRole_alwaysReverts` | No role holder can renounce. | proven |
| `check_initialize_notReplayable` | Neither proxy nor implementation can be initialized again. | proven |

trUSD has no blacklist or freeze; blacklist properties are on strUSD and on StakedTrUSDL2 below.

### strUSD vault (`StakedTrUSDHalmos`)

| Property | What it proves | Status |
| --- | --- | --- |
| `check_rewardAndLoss_onlyRewarder` | transferInRewards and reportLoss revert for anyone but the rewarder. | proven |
| `check_cooldown_boundedBy90Days` | After any call by anyone (admin included), cooldownDuration <= 90 days and no cooldown ends more than 90 days out. | proven |
| `check_setCooldownDuration_rejectsAbove90Days` | The admin cannot set a cooldown above 90 days. | proven |
| `check_withdrawRedeem_closedWhileCooldownOn` | ERC4626 withdraw and redeem are closed while a cooldown is configured. | proven |
| `check_unstake_notBeforeCooldownEnd` | unstake before cooldownEnd always reverts. | proven |
| `check_blacklisted_sharesAndCooldownFrozen` | A blacklisted holder's shares and cooldown move only by the admin's redistribute/seize. | proven |
| `check_blacklisted_cannotSendOrReceive` | No share transfer can involve a blacklisted address on either side. | proven |
| `check_owner_neverBlacklistedByOthers` | Nobody but the owner itself can blacklist the owner (narrowed, finding F-1). | proven |
| `check_privilegedState_onlyRoleHolders` | A caller with no role cannot change any role, vesting state, cooldown config or implementation. | proven |
| `check_upgradeToAndCall_onlyTimelock` | Upgrading reverts for every caller but the timelock. | proven |
| `check_admin_cannotTouchTimelockRoleOrUpgrade` | The admin cannot move TIMELOCK_ADMIN_ROLE or upgrade. | proven |
| `check_minShares_preserved` | Total supply is always 0 or >= 1e18 (MIN_SHARES) after any call. | proven |
| `check_rescueTokens_cannotTakeAsset` | rescueTokens refuses trUSD. | proven |
| `check_rescueOrphanFunds_onlyWithNoShares` | rescueOrphanFunds is unreachable while shares exist. | proven |

### strUSD vault arithmetic (`StakedTrUSDMathHalmos`)

Amounts (stake, reward, loss) are symbolic up to 2^96 (79bn trUSD).

| Property | What it proves | Status |
| --- | --- | --- |
| `check_transferInRewards_noInstantPriceJump` | A reward leaves totalAssets unchanged in the block it lands (no reward sandwich). | proven |
| `check_vesting_completeAfterPeriod` | From 8h after a reward on (any later time up to 2^32 s), unvested is 0 and totalAssets is stake + reward. | proven |
| `check_reportLoss_lowersAssetsByBurnt` | With nothing left vesting, a loss lowers totalAssets by exactly what it burnt. | bounded (8h or 24h after the last reward) |
| `check_reportLoss_rejectsAboveCap` | A loss report above 5% of totalAssets is refused. | proven |
| `check_reportLoss_lowersAssetsAtMostFivePercent` | An accepted loss report lowers totalAssets by at most 5%. | bounded (stake from a 4-point grid; loss symbolic) |
| `check_reportLoss_oncePerInterval` | After an accepted loss report, every further report within 24 hours is refused. | proven |
| `check_reportLoss_acceptedAfterInterval` | From 24 hours after a report on, a report within the cap is accepted again. | bounded (stake from a 4-point grid; elapsed time symbolic) |

The last four rows are the daily loss cap added in strUSD 1.1.0, the deployed version.

### Minting (`ToriMintingHalmos`)

Symbolic orders are priced at par (`_par`: any USDC amount below 2^64 units, trUSD = USDC x 1e12). Caps,
nonces, signatures, routing and recipients do not depend on the price; at par the price-band check is
exactly zero instead of a symbolic division.

| Property | What it proves | Status |
| --- | --- | --- |
| `check_mint_capsNeverExceeded` | Two mints in one block never exceed the global or per-asset cap, for any cap values. | bounded (par) |
| `check_redeem_capsNeverExceeded` | Same for redemptions. | bounded (par) |
| `check_disableMintRedeem_blocksEverything` | After the gatekeeper's kill switch no mint or redeem succeeds. | bounded (par) |
| `check_paused_blocksEverything` | While paused no mint or redeem succeeds. | bounded (par) |
| `check_notWhitelisted_cannotTrade` | A non-whitelisted sender never mints or redeems, even with a valid signature. | bounded (par) |
| `check_mint_eip1271_requiresApprovalOfExactDigest` | A contract-wallet order executes only if the wallet approved exactly `hashOrder(order)`. | bounded (par) |
| `check_mint_eip712_requiresSenderSignatureOverDigest` | An EOA order executes only if ecrecover over exactly `hashOrder(order)` is the sender; never for sender 0. | bounded (par) |
| `check_hashOrder_bindsEveryField` | Changing any order field changes the digest. | proven |
| `check_hashOrder_bindsChainId` | The digest differs between any two chain ids (valid EIP-155/EIP-2294 ids, both off the deployment chain). | proven |
| `check_nonce_noReplay` | Once a nonce executed for a sender, no order of either type with it executes again. | bounded (par) |
| `check_nonce_bitmapExact` | Nonce 0 is never valid; using n invalidates exactly the nonces with the same low 128 bits. | proven |
| `check_recipient_mustBeSenderOrApproved` | trUSD and collateral only go to the sender or an on-chain approved recipient. | proven |
| `check_mint_collateralOnlyToCustodians` | A mint moves exactly collateral_amount from the sender, all of it to custodians. | bounded (par; route of 1 to 3 legs, ratios symbolic) |
| `check_transferToCustody_onlyToCustodians` | transferToCustody moves exactly `amount`, only to custodians. | bounded (route of 1 to 3 legs, ratios symbolic; amount from the grid 1, 9_999, 10_001, 1e24 + 7) |
| `check_trUSDSupply_onlyMinterRole` | Only MINTER_ROLE can make ToriMinting mint trUSD. | proven |
| `check_custodiansAndTokens_onlyTimelockAdds` | Only the timelock adds a custodian, activates a token or sets the price band. | bounded (MINTER/REDEEMER operator excluded as caller; mint/redeem write none of these) |
| `check_privilegedState_onlyRoleHolders` | A caller with no role cannot change roles, caps, whitelist, custodians or pause. | proven |
| `check_gatekeeper_canOnlyRemovePowers` | The gatekeeper can revoke roles and zero caps, never grant a role or raise a cap. | proven |
| `check_admin_cannotBypassTimelock` | The admin cannot obtain TIMELOCK_ADMIN_ROLE, add a custodian or activate a token. | proven |

### Governance (`ToriTimelockHalmos`)

| Property | What it proves | Status |
| --- | --- | --- |
| `check_constructor_delayBounds` | The constructor accepts exactly delays in [1 day, 30 days]. | proven |
| `check_constructor_roleSplit` | Proposer, executor and canceller are exactly as passed; nobody, the timelock included, holds DEFAULT_ADMIN_ROLE. | proven |
| `check_roles_final` | No call by anyone, the timelock and every role holder included, adds or removes a member of any role. | proven |
| `check_operationState_onlyRoleHolders` | Only proposer, canceller or executor change any operation's state or the delay. | bounded (checked while the operation is waiting; the timelock's own calls are the next rows) |
| `check_execute_onlyExecutor` | A ready operation can be executed by the executor only. | proven |
| `check_schedule_rejectsShortDelay` | schedule rejects delays below the minimum. | proven |
| `check_execute_notBeforeMinDelay` | No operation executes earlier than max(minDelay, its own delay) after scheduling. | proven |
| `check_custodianAddition_onlyAfterDelay` | A ToriMinting custodian is only added by a timelock operation that waited out the delay. | proven |
| `check_updateDelay_staysInBounds` | Whatever governance executes (single or batch), the delay stays in [1 day, 30 days]. | proven |
| `check_selfCall_cannotEscapeBounds` | Executing any self-targeted call keeps the delay in bounds and the roles unchanged. | proven |

### PendleYTLock 4.0.0 (`PendleYTLockHalmos`, `PendleYTLockNoYieldHalmos`)

Pendle is modelled by `test/mocks/MockPendleYT.sol`. Where the state involves the share supply or the
yield index, lockers' deposits come from a 4-point grid and Pendle interest from a 4-point grid (see the
contract header); caller, function and arguments of the call under test stay symbolic.

| Property | What it proves | Status |
| --- | --- | --- |
| `check_withdrawalsPaused_blockExit` | While withdrawals are paused nobody can withdraw or redeem. | proven |
| `check_withdrawalPause_onlyGovernance` | Nobody but the timelock pauses withdrawals; nobody but timelock or admin unpauses. | proven |
| `check_principal_alwaysBacked` | The lock's YT balance always covers totalAssets, after any call by anyone but the timelock. | bounded (deposit grid) |
| `check_yieldReserve_backedAcrossDeposit` | A new depositor gets no share of past yield, nobody is diluted, the reserve stays backed. | bounded (deposit and interest grids) |
| `check_harvest_attributesAtMostReceived` | A harvest never attributes more than it received. | bounded (deposit and interest grids) |
| `check_rescueTokens_cannotTakePrincipalOrYield` | rescueTokens refuses the YT and the SY. | proven |
| `check_privilegedState_onlyRoleHolders` | A caller with no role cannot change roles, the emergency pause or the implementation. | proven |
| `check_upgradeToAndCall_onlyTimelock` | Upgrading reverts for every caller but the timelock. | proven |
| `check_admin_cannotBypassTimelock` | The admin cannot move TIMELOCK_ADMIN_ROLE, upgrade or pause withdrawals. | proven |

`PendleYTLockNoYieldHalmos` sets the lock up in yield-off mode (`initializeWithoutYield`), the mode of a
lock whose SY pays nothing. Deposits come from the same 4-point grid.

| Property | What it proves | Status |
| --- | --- | --- |
| `check_yieldOff_staysOff` | No call by anyone but the timelock (which can upgrade) turns yield on. | proven |
| `check_yieldOff_yieldCallsRevert` | Every yield entry point (claim, claim to, Pendle claim, orphan rescue, late initialisation) reverts for every caller, the admin included. | proven |
| `check_yieldOff_principalAlwaysBacked` | The lock's YT balance always covers totalAssets, after any call by anyone but the timelock. | bounded (deposit grid) |
| `check_yieldOff_withdrawalsPausedBlockExit` | While withdrawals are paused nobody can withdraw or redeem, in this mode too. | proven |

### Silo and rewards distributor (`TrUsdSiloHalmos`, `StakingRewardsDistributorHalmos`)

| Property | What it proves | Status |
| --- | --- | --- |
| `check_silo_onlyVaultMovesFunds` | Nobody but the vault moves any token out of the silo. | proven |
| `check_silo_rescueCannotTakeTrUSD` | Even the vault cannot pull trUSD through the rescue path. | proven |
| `check_silo_coversAllCooldowns` | The silo always holds at least every open cooldown, after any vault call (admin included). | proven |
| `check_onlyOperatorMovesRewards` | Only the operator moves trUSD out or changes vesting. | proven |
| `check_config_onlyOwner` | Only the owner changes operator, owner or the vault allowance. | proven |
| `check_owner_cannotRescueTrUSDOrRenounce` | The owner cannot rescue trUSD or renounce ownership. | proven |
| `check_transferInRewards_exact` | A reward moves exactly the amount, vests all of it, and does not move the price. | proven |

### strUSD on other chains (`StakedTrUSDL2Halmos`)

| Property | What it proves | Status |
| --- | --- | --- |
| `check_supply_onlyMinterIncreases` | Only a granted minter raises supply. | proven |
| `check_mint_neverAboveMaxSupply` | Two mints never exceed maxSupply. | proven |
| `check_blacklisted_frozen` | A blacklisted balance moves only by the owner, the CCIP pool and the blacklister included. | proven |
| `check_blacklist_onlyBlackLister` | Only the blacklister changes entries (the owner's redistribution restores them). | proven |
| `check_mintToBlacklisted_reverts` | A pool mint to a blacklisted address reverts, so the inbound CCIP message fails atomically. | proven |
| `check_config_onlyOwner` | Only the owner changes blacklister, minters/burners or the CCIP admin. | proven |

CCIP token pools are Chainlink's own contracts and are not in scope.

## Not in the suite

None of these is a `check_` function in this directory; each needs either a different solver setup or
a different formulation. They are covered by Foundry tests that are kept outside this repository.

| Property | Why it is not here | Covered by |
| --- | --- | --- |
| strUSD ERC4626 rounding: previews round toward the vault; deposit-then-redeem and mint-then-redeem never profit; a cooldown books no more than deposited | Every conversion goes through OpenZeppelin `Math.mulDiv`, whose 512-bit `mulmod(x, y, not(0))` is intractable for yices and z3 with any symbolic operand, even with the vault state concrete. | Stateful invariant tests of the vault (no over-issued shares, share price only falls on a reported loss, vault solvency) and fuzz tests |
| strUSD vesting monotonic inside the 8h window | `(VESTING_PERIOD - elapsed) * vestingAmount / VESTING_PERIOD` with a symbolic amount timed out at every width tried (down to 16-bit), with elapsed symbolic or on a concrete grid. | Invariant tests (unvested amount bounded by the vesting amount, share price only falls on a reported loss) |
| strUSD reportLoss while rewards are still vesting (loss absorbed by unvested rewards, vault stays solvent, price never rises) | Same division, plus the re-solved vesting amount. Proven only with nothing vesting (`check_reportLoss_lowersAssetsByBurnt`). | The vault solvency invariant, loss-report scenario tests and fuzz tests |
| strUSD reportLoss burns exactly min(loss, balance) and keeps balance >= unvested | Times out even with nothing vesting. | Fuzz tests of reportLoss and the vault solvency invariant |
| PendleYTLock yield reserve stays backed after any call (`reserved + orphaned <= SY balance`, claimable <= reserved) | Arbitrary call over the yield index exceeds the CI budget even with deposits and interest on grids. The deposit path is proven (`check_yieldReserve_backedAcrossDeposit`). | Unit tests of the lock's yield accounting and of yield-theft scenarios |
| PendleYTLock deposit-then-redeem profit | OZ `mulDiv`, as above. | Unit tests of the lock |
| Minting at a non-par price (price band) | `difference * 10_000 / trusdAmount` with symbolic amounts; properties are proven at par. | Unit tests of ToriMinting |

## Findings

**F-1 (low): the strUSD owner can blacklist itself.** `addToBlacklist` and `removeFromBlacklist` refuse
the owner (`notOwner`), but DEFAULT_ADMIN_ROLE is the role admin of FULL_RESTRICTED_STAKER_ROLE, so the
owner can call `grantRole(FULL_RESTRICTED_STAKER_ROLE, owner())` directly. halmos counterexample:
caller = owner, `grantRole(keccak256("FULL_RESTRICTED_STAKER_ROLE"), owner)`. Present in 1.0.0 and in
1.1.0, the deployed version. Only the owner itself can do this and it can be undone with `revokeRole`,
so it is noted and not changed; the invariant the `notOwner` guard is written to enforce does not hold
for the owner's own calls. The property in CI is the narrowed `check_owner_neverBlacklistedByOthers`.

**F-2 (medium, fixed): a sole timelock role holder could disable governance permanently.** The
previous version of ToriTimelock did not override `renounceRole`, and its constructor revokes
DEFAULT_ADMIN_ROLE from everyone, so a renounced role could never be granted again. halmos
counterexamples against that version: the proposer calls `renounceRole(PROPOSER_ROLE, proposer)`, or
the executor calls `renounceRole(EXECUTOR_ROLE, executor)`. After either, nothing behind the timelock
(trUSD/strUSD upgrades, minter changes, custodian and collateral additions) could ever execute again.
It needs a transaction from the role holder itself, so it is a key-holder mistake or compromise rather
than an external attack.

Fixed in the version of ToriTimelock in this repository: `renounceRole` reverts with
`CantRenounceRole()`, and `check_roles_final` proves that no call by anyone adds or removes a member
of any role. trUSD, strUSD and PendleYTLock block `renounceRole` as well. ToriMinting does not; its
TIMELOCK_ADMIN_ROLE holder is the timelock, so renouncing it there is itself a timelock operation.

## Mutation check

Every property above was run against at least one deliberately broken copy of the code (a guard
removed, a bound or constant changed, a rounding flipped, a privileged function opened up) and had to
produce a counterexample; the mutation was then reverted. Mutations were applied in a scratch checkout
only; none is in the repository.
