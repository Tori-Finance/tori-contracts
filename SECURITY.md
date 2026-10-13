# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Tori Protocol, please report it
privately to **security@tori.finance**. Do not open a public GitHub issue.

## Response Timeline

| Stage                | SLA       |
|----------------------|-----------|
| Acknowledgment       | 24 hours  |
| Initial assessment   | 72 hours  |
| Remediation plan     | 1 week    |
| Public disclosure    | After fix |

We follow coordinated disclosure: once a fix is deployed, we will publish a
post-mortem and credit the reporter (with their permission).

## Bug Bounty

A Sherlock-hosted bug bounty program is live at mainnet launch with a
maximum reward of **$1,000,000** and severity-scaled payouts. The current
URL will be published on <https://docs.tori.finance/security/audits> when
the program opens.

## Audits

| Firm         | Report                                              |
|--------------|-----------------------------------------------------|
| Sherlock     | Collaborative audit, final commit `eb507400` (Feb 2026) |
| Nethermind   | NM-0854, final commit `4ac4e51` (Mar 2026)          |

Full audit reports are available at <https://docs.tori.finance/security/audits>.

## Scope

In scope:
- The Solidity contracts in this repository, at the addresses listed in README.md.

Out of scope:
- Testnet deployments.
- Issues in third-party dependencies that have already been audited and
  reported (OpenZeppelin, Chainlink CCIP).
- Self-DoS / griefing without monetary impact.

## Safe Harbor

Tori provides safe harbor for good-faith security research conducted under
the bug-bounty program's terms. Activities that exfiltrate user funds, do
not return them, or target users / counterparties rather than the protocol
are not covered.
