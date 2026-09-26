# Rebuilding the KAY9 record yourself

This is the procedure for gate 3 of `docs/LAUNCH_READINESS.md`: somebody outside KAY9, given only
the chain and the batch documents, rebuilds the feed kay9.io shows and finds it identical. It takes
about half an hour and needs no account, key or wallet, and nothing from KAY9 except this page.

## 1. What the record is

KAY9's watchdog scans tokens on Robinhood Chain (chain id 4663) and commits the results in batches
to one contract, `KAY9ScanRegistry` at `0x79778723c021386F3C7727289A30716edaa635A1`. Each batch
leaves three things behind:

- **On chain, the batch**: a Merkle root, the number of scans, the engine version and the URI of
  the batch document (`getBatch(batchId)`).
- **On IPFS, the batch document**: a JSON file listing every scan in the batch. The root on chain
  is computed from it, so the document cannot be changed after the commit without the root no
  longer matching.
- **On chain, one `AssetScanned` event per shown scan**: the numbers the website displays. A scan
  whose headline is withheld, because under 60 % of its weight was measured (flag bit 20), is in
  the document and the root but has no event.

The website reads the events. The contract does not check that the events agree with the root;
this procedure does.

## 2. What you need

- Node.js 20 or later, and a POSIX shell for step 3 (on Windows, Git Bash or WSL).
- `rebuild-record.mjs`, from the public repository `kay9T/kay9-protocol` (`tools/`). It is one
  file of about 180 lines with a single dependency; reading it first is encouraged. Or write your
  own from the definitions in §5; nothing in it is specific to KAY9's own code.
- A public RPC for Robinhood Chain. The script defaults to `https://rpc.mainnet.chain.robinhood.com`;
  `--rpc <url>` uses another.

```bash
mkdir kay9-check && cd kay9-check
npm install viem@2
# copy tools/rebuild-record.mjs from kay9T/kay9-protocol into this folder
```

## 3. The steps

**Step 1. Take what the website shows.** Open <https://kay9.io/feed> and use **Download as CSV**.
The file holds every scan the page loaded, as read from the chain, before any filter: the events
of the last 200,000 blocks, roughly five and a half hours, newest first and at most 200 of them.
Its name ends with the block of the newest row.

**Step 2. Rebuild the record.** Note the highest `batch_id` in the file (column 4) and rebuild up
to that batch:

```bash
node rebuild-record.mjs --out rebuilt.csv --to <highest batch_id in the file>
```

For every batch the script reads the batch from the contract, fetches its document, recomputes
every leaf and the root, and requires root, count and engine version to match the chain. It then
reads the batch's `AssetScanned` events and requires each to match an entry of the document, field
by field. It exits with code 0 when everything matched, and with code 2 and a list of every
mismatch otherwise.

**Step 3. Compare.** Every event of a batch is in the one transaction that committed it, so the
website's file holds whole batches, with one exception: when it holds 200 rows the page stopped at
its cap, and its lowest batch may be cut short. The third line leaves that batch out in that case.

```bash
tail -n +2 kay9-feed-*.csv | cut -d, -f4- | sort > site.txt
low=$(cut -d, -f1 site.txt | sort -n | head -1)
[ "$(wc -l < site.txt)" -ge 200 ] && low=$((low + 1))
awk -F, -v low="$low" '$1 >= low' site.txt > site-compared.txt
tail -n +2 rebuilt.csv | awk -F, -v low="$low" '$1 >= low' | sort > rebuilt-compared.txt
diff site-compared.txt rebuilt-compared.txt && echo "identical: $(wc -l < site-compared.txt) rows"
```

An empty diff means every score kay9.io showed in those batches is a scan committed under the
root on chain, with the same asset, score, confidence, flags and block. Any line the diff prints is
a finding, and so is a non-zero exit in step 2.

**Step 4. Report it.** For gate 3 the evidence is your run, not ours. Keep the two CSV files, the
output of both commands and the date, and send them to KAY9: the Telegram group
<https://t.me/KAY9Pack>, or @kay9_io on X. They are published beside the gate.

## 4. What an empty diff proves, and what it does not

It proves the website shows the record and nothing else: no score on the feed that is not
committed on chain, and none altered after the commit.

It does not prove the scores are right. That is a different check: re-run the engine on a token at
the block its scan was pinned to and compare the result (`docs/BASIC_SCAN.md` §8). It also does not
cover the reports behind each scan; §6 is how to check those.

## 5. The definitions, for writing your own

Everything the script does follows from the contract, `KAY9ScanRegistry.scanLeaf` and
`verifyScan`.

- `chainKey` is `keccak256("eip155:4663")`,
  `0x4c583a970094e332eaa480a6f7478093ea9b680af9ffceecda5867d8bb2afb4a`.
- `assetId` is the token address, lower case, left-padded to 32 bytes.
- **The batch document** is JSON: `version`, `chainId`, `engineVersion`, `root`, and `scans`, a list
  in leaf order. Each scan carries `chainKey`, `assetId`, `overallTrust`, `confidence`, `flags` and
  `scannedAtBlock` (both decimal strings), `reportHash` and `reportURI`. The engine version of the
  leaf is the document's, not the entry's.
- **A leaf** is
  `keccak256(keccak256(abi.encode(bytes32 chainKey, bytes32 assetId, uint8 overallTrust, uint8 confidence, uint64 flags, uint32 engineVersion, uint64 scannedAtBlock, bytes32 reportHash)))`.
- **The tree** pairs nodes left to right in document order. A parent is
  `keccak256(lower ++ higher)` of its two children compared as numbers. An odd last node moves up
  unchanged, and a single leaf is its own root.
- **Withheld** means bit 20 of `flags` is set. Such an entry has no `AssetScanned` event.
- **The events** of a batch are emitted in the transaction that committed it, in the block
  `getBatch(batchId).committedBlock`, which is the chain's own block number (the one `eth_getLogs`
  uses).

## 6. Checking the reports behind the scans (optional)

Each entry's `reportURI` points at the full scan report on IPFS, and `reportHash` is the keccak256
of that report's canonical JSON: keys sorted, no whitespace, UTF-8. The pinning service stores the
parsed JSON, so the bytes a gateway returns may be formatted differently. Parse the report,
re-serialise it canonically, and hash that.
