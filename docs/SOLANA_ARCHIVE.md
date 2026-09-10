# Solana archive capture and replay

Engine **1.4.0** can replay a recorded Solana read set in the analysis engine and audit worker.
Standard RPC still cannot reconstruct arbitrary historical account state. Capture stores the
current finalized bank for later use; pre-existing history requires an archive export.

## Capture

Build the watchdog, configure SOLANA_RPC_URL, and run:

```sh
npm run build -w services/watchdog
node services/watchdog/dist/cli.js snapshot-solana So11111111111111111111111111111111111111112 ./solana-snapshots
```

Capture discovers up to eight pool candidates, then reads the mint, supported pools, vaults,
configurations, quote mints, LP mints and sampled holder accounts in one getMultipleAccounts call.
When largest-account rankings are available, their RPC context slot must exactly match that batch;
capture retries at most three times. minContextSlot is not used as a historical pin. Ranking amounts
must agree with the captured token-account bytes. If rankings are unavailable, largestAccounts is
null and the replay keeps holder coverage unmeasured.

The slot's block time comes from getBlockTime. History capture reads at most four mint-signature
pages and one 100-signature page for each of four validated pools, then at most 128 transaction
receipts. Anything after the captured slot/time is excluded. Creator-authority history and any
other absent records remain unmeasured unless supplied by an archive export; capture does not add
later account state to a previously captured bank.

Files are published completely before becoming visible, using exclusive hard links:

```text
solana-snapshots/<mint>/slot-<slot>.json
solana-snapshots/<mint>/timestamp-<unix-seconds>.json
```

Existing keys cannot be overwritten with different content. Identical retries are allowed.
Several Solana slots can have the same block time; the timestamp key deliberately selects one
immutable export. All auditors must use that same selection. Conflicting captures fail instead of
silently changing a queued job's inputs. A slot file can exist even if publishing its timestamp
alias fails because that second key already exists.

## Replay locally

Use the slot printed by capture:

```sh
node services/watchdog/dist/cli.js replay-solana <mint> ./solana-snapshots <slot> deep
```

This prints the canonical report without network access. Every read comes from the stored export;
missing data returns unavailable, never a live-RPC fallback. The report contains analyzedAtBlock
and snapshotHash, the hash of the complete canonical input export.

The TypeScript entry point accepts the same archive as options.solanaSnapshot, together with
atBlock or atTimestamp. It rejects a different mint, mismatched pin, future transaction evidence,
malformed envelopes or input budgets exceeded.

## Audit worker

Set SOLANA_SNAPSHOT_DIR to a directory mounted read-only in each auditor's runtime. The worker
looks up the asset and the job's exact requestedAt timestamp (or exact slot for a block pin),
passes the export to the engine and checks that the result retained the archive slot and digest.
If the export is absent, the job remains unresolved; it never selects the nearest or current state.
The worker's existing retry, cursor and expiry behavior still applies.

For a local Docker rehearsal, mount the same directory into each operator, for example:

```yaml
environment:
  SOLANA_SNAPSHOT_DIR: /solana-snapshots
volumes:
  - ./solana-snapshots:/solana-snapshots:ro
```

This is a runtime mount, not a directory to copy into a production image. No signing key is needed
for capture or replay. Capturing one mint once does not provision coverage for later requests.

## Trust and coverage

The digest establishes input identity and reproducibility, **not a cryptographic account-state
proof**. Capture trusts the configured finalized RPC; imported exports trust their archive source.
Sharing one unverified archive across operators does not create independent observations. Before
production use, establish archive provenance, immutable publication, equivalent auditor inputs,
and coverage of the timestamps the worker will request. Solana historical account proof verification
and a continuously operated archive service are not supplied by this CLI.

The public RPC smoke test captured slot **445546022**, block time **1788936355**, and successfully
replayed it locally. Its holder query was rate-limited, so the export contained one mint account,
12 transaction records and explicitly unavailable holder data. This proves capture/storage/replay,
not comprehensive public-RPC coverage or a production quorum deployment.

Protocol references: [getMultipleAccounts](https://solana.com/docs/rpc/http/getmultipleaccounts),
[getTokenLargestAccounts](https://solana.com/docs/rpc/http/gettokenlargestaccounts),
[getBlockTime](https://solana.com/docs/rpc/http/getblocktime).
