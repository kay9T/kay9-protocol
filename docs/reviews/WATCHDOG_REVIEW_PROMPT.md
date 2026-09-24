# Watchdog-stack model review — the prompt

This is the exact text given to every model that reviews the watchdog stack for gate 6 of
[`LAUNCH_READINESS.md`](../LAUNCH_READINESS.md). The watchdog goes to mainnet about a month before
the token, and its contracts are as immutable as the launch path's, so gate 6 asks for the same two
model-family reviews of them at the commit to be deployed. The same prompt goes to each model
family, and it is published with the reviews. Replace `<COMMIT>` with the full commit hash of the
latest `watchdog-review-N` tag before sending.

This is a model review, not a professional audit. No firm is accountable for it and nobody carries
liability for a miss. KAY9 is never described as "audited" or "verified safe" because of it.

---

You are reviewing the watchdog stack of KAY9 for security and correctness. KAY9 is an on-chain audit
protocol on Robinhood Chain (an Arbitrum Orbit chain, chain id 4663). The watchdog stack is the part
that goes live before the KAY9 token exists: an auditor set with a quorum, an append-only report
registry, an audit hub that turns agreeing auditor signatures into registry entries, and a registry
of automatic basic scans committed in Merkle batches. Nobody pays for anything in this protocol. The
code is public at https://github.com/kay9T/kay9-protocol.

**Commit.** Review exactly commit `<COMMIT>`. Before anything else, quote the first two lines of
`src/KAY9AuditHub.sol` at that commit so the reader knows which tree you read. If you cannot read
that commit, say so and stop. Do not review from memory or from another version.

**In scope**, and nothing else:

- `src/KAY9AuditorRegistry.sol`: the auditor set and the quorum threshold, owned by the timelock.
- `src/KAY9AuditHub.sol`: requests, EIP-712 auditor attestations, quorum, disputes, expiry, and the
  permissionless `publishWatchdogReport`. At watchdog deployment it has no access vault;
  `setAccessVault` binds one once, at the token launch.
- `src/KAY9Registry.sol`: the append-only report log, writable only by its hub.
- `src/KAY9ScanRegistry.sol`: Merkle batches of basic scans, committed by an authorised scanner or
  an auditor, with `verifyScan` and the per-asset latest score.
- `script/DeployWatchdog.s.sol`: what these contracts are deployed with, the 48-hour
  `TimelockController` that owns them, and what the deploying key keeps afterwards.
- Any library or interface these import from `src/`.

**Out of scope**: the launch path (`KAY9Genesis`, `KAY9Token`, `KAY9TeamVesting`,
`KAY9LiquidityLock`), reviewed separately; `KAY9AccessVault`, except as far as the hub calls it;
the website and the off-chain services. OpenZeppelin code under `lib/` is third-party; report a
finding in it only if KAY9 uses it wrongly.

**The properties the design claims, which is what to try to break:**

1. After deployment and `acceptOwnership`, only the 48-hour timelock can change the auditor set, the
   threshold, the scanners, the SLA, the request pause or the access vault, and the deploying key
   keeps no role anywhere.
2. A report enters `KAY9Registry` only through the hub, and only with at least `threshold` distinct
   current auditors signing the same EIP-712 digest. A signature cannot be replayed on another
   chain, another deployment or another job.
3. The report registry is append-only. No record is ever modified or deleted, and `latest` is the
   most recent record, never a merge of several.
4. Contradictory auditor results are never averaged. When agreement becomes arithmetically
   impossible the job is disputed on-chain, and an auditor holds at most one position per job.
5. Only an authorised scanner or a current auditor can commit a scan batch. A committed batch can
   never be altered or removed, `verifyScan` accepts exactly the leaves the batch was built from,
   and a batch holds at most 500 scans.
6. Before `setAccessVault`, `requestAudit` reverts and `publishWatchdogReport` works. The vault can
   be set once, by the owner only, and never changed afterwards.
7. Nobody pays. None of these contracts takes a fee, holds ETH or tokens, or can move anyone's funds.
8. Removing auditors can halt the quorum but can never let fewer than `threshold` auditors publish,
   and the threshold always stays within [1, auditor count] while any auditor exists.
9. Nothing a requester declares or pays can change a score. `declaredRequesterKind` is recorded as
   metadata and never verified or used in scoring.
10. Every block number recorded is the chain's own height (`ArbSys.arbBlockNumber()`, about 0.1 s),
    never `block.number`, which on this chain is the parent chain's height.

**What to return.** One markdown document and nothing outside it:

- Findings ranked most severe first. For each: a title, a severity, the file and line, a concrete
  failure scenario (who does what, in which order, and what is lost or wrongly allowed), and a
  suggested fix.
- A section listing each of the ten properties above as **holds**, **broken** or **could not
  conclude**, with the reason.
- A section stating plainly what you did **not** cover or could not verify.
- Your model name and version, as exactly as you know them.

Do not soften a finding and do not invent one. If you are unsure, say that you are unsure and why.
