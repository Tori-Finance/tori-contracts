# Tori Protocol contracts

The Solidity source of the Tori Protocol contracts that are deployed on mainnet, at the versions
that are live. Nothing else is in this repository: no tests, deployment scripts or mocks.

Tori is a stablecoin protocol. trUSD is minted and redeemed against collateral through signed
orders, and strUSD is an ERC-4626 vault over trUSD that earns the protocol's yield.

## Contracts

| Contract | Path | What it does |
|---|---|---|
| TrUSD | `contracts/core/TrUSD.sol` | The trUSD stablecoin (ERC-20, UUPS proxy). Only ToriMinting can mint. |
| ToriMinting | `contracts/core/ToriMinting.sol` | Mints and redeems trUSD against collateral, from EIP-712 orders (EIP-1271 for contract signers), with per-block limits. |
| StakedTrUSD | `contracts/core/StakedTrUSD.sol` | strUSD: ERC-4626 vault over trUSD (UUPS proxy), with rewards vesting, a withdrawal cooldown and a daily cap on reported losses. |
| TrUsdSilo | `contracts/core/TrUsdSilo.sol` | Holds trUSD during the strUSD cooldown. |
| StakingRewardsDistributor | `contracts/core/StakingRewardsDistributor.sol` | Moves rewards into the strUSD vault. |
| PendleYTLock | `contracts/core/PendleYTLock.sol` | Holds Pendle YT positions and distributes their yield (UUPS proxy). |
| ToriTimelock | `contracts/governance/ToriTimelock.sol` | The timelock that governs privileged changes. |
| StakedTrUSDL2 | `contracts/omnichain/StakedTrUSDL2.sol` | strUSD on other chains: a Chainlink CCIP burn/mint token with a blacklist. |
| CurveRateOracle | `contracts/integrations/CurveRateOracle.sol` | 18-decimal wrapper of RedStone's strUSD rate feed, used by Curve pools on Monad. |

`contracts/interfaces/` holds the interfaces these contracts import.

## Deployments

### Ethereum

| Contract | Address |
|---|---|
| TrUSD (proxy) | [`0xd0580192E98eA6CEB9c7b6191Ed2E27560911697`](https://etherscan.io/address/0xd0580192E98eA6CEB9c7b6191Ed2E27560911697) |
| StakedTrUSD (proxy) | [`0x280839980a7eD0D7717F64125fE241012E5F5815`](https://etherscan.io/address/0x280839980a7eD0D7717F64125fE241012E5F5815) |
| ToriMinting | [`0xe16b821B9F6B0a6f06a2C4a61D5d1f71cFa53F1E`](https://etherscan.io/address/0xe16b821B9F6B0a6f06a2C4a61D5d1f71cFa53F1E) |
| TrUsdSilo | [`0xF7c0d8853E69DCD37ee7599c6280d2632F3360B4`](https://etherscan.io/address/0xF7c0d8853E69DCD37ee7599c6280d2632F3360B4) |
| StakingRewardsDistributor | [`0xa0C49fFa4B7941830235cde974d9B2a8420CD375`](https://etherscan.io/address/0xa0C49fFa4B7941830235cde974d9B2a8420CD375) |
| ToriTimelock | [`0x7af35ab3E5373dA511c5F1331f44335a36dA1A55`](https://etherscan.io/address/0x7af35ab3E5373dA511c5F1331f44335a36dA1A55) |
| PendleYTLock, strUSD (proxy) | [`0x6569C554cBf71Dfcc32aEc48B0eDd2582f5C4a96`](https://etherscan.io/address/0x6569C554cBf71Dfcc32aEc48B0eDd2582f5C4a96) |
| PendleYTLock, trUSD (proxy) | [`0x10b2487173d9F7087c8bdce9E70fd135212A8d7d`](https://etherscan.io/address/0x10b2487173d9F7087c8bdce9E70fd135212A8d7d) (see the note below) |

### Monad

| Contract | Address |
|---|---|
| StakedTrUSDL2 (strUSD) | [`0x683fb58ee77172626D5B49087DdAc71eF7825d20`](https://monadvision.com/address/0x683fb58ee77172626D5B49087DdAc71eF7825d20) |
| CurveRateOracle | [`0x33D3ad3a9f0eC36EfbE76425C0f33207dD5a8A98`](https://monadvision.com/address/0x33D3ad3a9f0eC36EfbE76425C0f33207dD5a8A98) |

### Pharos

| Contract | Address |
|---|---|
| StakedTrUSDL2 (strUSD) | [`0x25419E949b485d481BED4ea0c5A0496f6C7f7c63`](https://pharosscan.xyz/address/0x25419E949b485d481BED4ea0c5A0496f6C7f7c63) |

trUSD on Monad and Pharos is Chainlink's standard CCIP burn/mint token, so its source is not here.

**Note on the trUSD PendleYTLock:** its implementation is an earlier version of `PendleYTLock`
than the one in this repository. The strUSD lock runs the version here.

## Building

```bash
npm install
forge build
```

Solidity 0.8.28, optimizer 200 runs, EVM `cancun`, no IR (`foundry.toml`, default profile). This
build reproduces the deployed runtime code of every contract above except the trUSD PendleYTLock.
StakedTrUSD, StakedTrUSDL2 and CurveRateOracle match byte for byte. The contracts deployed at
launch were compiled with an IPFS metadata hash, so their last 41 bytes differ; the code itself
is identical.

## Audits

| Firm | Scope | Report |
|---|---|---|
| Sherlock | Collaborative audit, final commit `eb507400` (Feb 2026) | [docs.tori.finance/security/audits](https://docs.tori.finance/security/audits) |
| Nethermind | NM-0854, final commit `4ac4e51` (Mar 2026) | [docs.tori.finance/security/audits](https://docs.tori.finance/security/audits) |

The Nethermind audit covered TrUSD, StakedTrUSD, TrUsdSilo, ToriMinting,
StakingRewardsDistributor and ToriTimelock. PendleYTLock, StakedTrUSDL2 and CurveRateOracle were
not in its scope, and StakedTrUSD's daily loss cap was added after it.

## Security

Report vulnerabilities privately to **security@tori.finance**; see [SECURITY.md](SECURITY.md).

## License

Each file carries its own SPDX identifier. Most are `GPL-3.0` or `MIT`; `CurveRateOracle.sol` is
`BUSL-1.1`.
