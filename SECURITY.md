# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in Tori Protocol, please report it
privately to **security@tori.finance**. Do not open a public GitHub issue.

## Response Timeline

| Stage                | Target                 |
|----------------------|------------------------|
| Acknowledgment       | Within 24 hours        |
| Initial assessment   | Within 10 business days |
| Public disclosure    | After the fix is live  |

Send reports in plain text. We do not open attachments, so put the description, the affected contract
and function, and the proof of concept (a Foundry test against a mainnet fork is ideal) in the body of
the email.

## Bug Bounty

The bug bounty is live, with rewards of up to **$1,000,000** by severity. Scope, exclusions and rewards
are on <https://docs.tori.finance/security/audits#bug-bounty>. Only the first valid report of an issue is
eligible, issues that need a privileged role or a compromised key are out of scope, and rewards are paid
after an identity and sanctions check.

## Audits

| Firm         | Report                                              |
|--------------|-----------------------------------------------------|
| Sherlock     | Collaborative audit, final commit `eb507400` (Feb 2026) |
| Nethermind   | NM-0854, final commit `4ac4e51` (Mar 2026)          |

Full audit reports are available at <https://docs.tori.finance/security/audits>.

## Scope

In scope:
- The Solidity contracts in this repository, at the addresses listed in README.md.
- The website, app and API (tori.finance, app.tori.finance): Critical issues only, with a reward of up
  to $50,000. See the docs for what counts as Critical there.

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
