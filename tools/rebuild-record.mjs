#!/usr/bin/env node
/**
 * Rebuild the KAY9 watchdog record from the chain and the batch documents, without KAY9.
 *
 *   npm install viem@2
 *   node rebuild-record.mjs --out rebuilt.csv [--from 0] [--to <last batch>] [--rpc <url>]
 *
 * For every batch in KAY9ScanRegistry on Robinhood Chain (4663) it:
 *   1. reads the batch from the contract (`getBatch`): root, count, engine version, document URI;
 *   2. fetches the document from IPFS through any public gateway;
 *   3. recomputes every leaf and the Merkle root from the document, and requires the root and the
 *      count to equal the contract's;
 *   4. reads the batch's `AssetScanned` events and requires each to match a leaf of the document,
 *      field for field: the events are what a website shows, the root is what the chain proves;
 *   5. writes the entries the events should carry (the document's entries whose headline was not
 *      withheld, flag bit 20) as CSV rows, newest batch first.
 *
 * The CSV's columns are batch_id,chain_key,asset_id,overall_trust,confidence,flags,scanned_at_block:
 * columns 4 to 10 of the "Download as CSV" file on kay9.io/feed. docs/REBUILD_THE_RECORD.md says how
 * to diff the two. Nothing here is signed or sent; it only reads.
 *
 * The leaf and the tree are defined by the contract (KAY9ScanRegistry.scanLeaf and verifyScan):
 *   leaf = keccak256(keccak256(abi.encode(bytes32 chainKey, bytes32 assetId, uint8 overallTrust,
 *            uint8 confidence, uint64 flags, uint32 engineVersion, uint64 scannedAtBlock,
 *            bytes32 reportHash)))
 *   parent = keccak256(min(a, b) ++ max(a, b)); an odd last node is promoted unchanged.
 */
import { writeFile } from 'node:fs/promises';
import { createPublicClient, encodeAbiParameters, encodePacked, http, keccak256, parseAbi, parseAbiItem } from 'viem';

const REGISTRY = '0x79778723c021386F3C7727289A30716edaa635A1';
const GATEWAYS = ['https://gateway.pinata.cloud/ipfs/', 'https://ipfs.filebase.io/ipfs/', 'https://ipfs.io/ipfs/', 'https://dweb.link/ipfs/'];
const WITHHELD_BIT = 20n;
const ABI = parseAbi([
  'function batchCount() view returns (uint256)',
  'function getBatch(uint256 batchId) view returns ((bytes32 root, uint32 count, uint32 engineVersion, uint64 committedAt, uint64 committedBlock, address scanner, string uri))',
]);
const ASSET_SCANNED = parseAbiItem(
  'event AssetScanned(bytes32 indexed chainKey, bytes32 indexed assetId, uint256 indexed batchId, uint8 overallTrust, uint8 confidence, uint64 flags, uint64 scannedAtBlock)',
);

function arg(name, fallback) {
  const index = process.argv.indexOf('--' + name);
  return index >= 0 ? process.argv[index + 1] : fallback;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Retries what a public endpoint sheds under load: 429s, timeouts, dropped connections. */
async function patiently(fn) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await fn();
    } catch (error) {
      const text = String(error?.message ?? error);
      if (attempt >= 7 || !/429|Too Many|timeout|timed out|fetch failed|ECONNRESET/i.test(text)) throw error;
      await sleep(Math.min(1000 * 2 ** attempt, 20_000));
    }
  }
}

async function fetchDocument(uri) {
  const cid = uri.replace('ipfs://', '');
  let last;
  for (let round = 0; round < 3; round++) {
    for (const gateway of GATEWAYS) {
      try {
        const response = await fetch(gateway + cid, { signal: AbortSignal.timeout(30_000) });
        if (response.ok) return await response.json();
        last = new Error(gateway + ' answered ' + response.status);
      } catch (error) {
        last = error;
      }
    }
    await sleep(2_000);
  }
  throw new Error('document ' + uri + ' unreachable: ' + last);
}

function leafOf(entry, engineVersion) {
  const inner = keccak256(
    encodeAbiParameters(
      [
        { type: 'bytes32' }, { type: 'bytes32' }, { type: 'uint8' }, { type: 'uint8' },
        { type: 'uint64' }, { type: 'uint32' }, { type: 'uint64' }, { type: 'bytes32' },
      ],
      [
        entry.chainKey, entry.assetId, Number(entry.overallTrust), Number(entry.confidence),
        BigInt(entry.flags), Number(engineVersion), BigInt(entry.scannedAtBlock), entry.reportHash,
      ],
    ),
  );
  return keccak256(inner);
}

function rootOf(leaves) {
  let level = leaves;
  while (level.length > 1) {
    const above = [];
    for (let i = 0; i < level.length; i += 2) {
      const a = level[i];
      const b = level[i + 1];
      if (b === undefined) above.push(a);
      else above.push(keccak256(encodePacked(['bytes32', 'bytes32'], BigInt(a) < BigInt(b) ? [a, b] : [b, a])));
    }
    level = above;
  }
  return level[0];
}

async function main() {
  const rpc = arg('rpc', 'https://rpc.mainnet.chain.robinhood.com');
  const out = arg('out');
  if (!out) throw new Error('--out <file.csv> is required');
  const client = createPublicClient({ transport: http(rpc, { retryCount: 0 }) });
  const count = await patiently(() => client.readContract({ address: REGISTRY, abi: ABI, functionName: 'batchCount' }));
  const from = BigInt(arg('from', '0'));
  const to = BigInt(arg('to', String(count - 1n)));
  if (to >= count) throw new Error('the registry holds ' + count + ' batches; --to ' + to + ' is past the last');

  const rows = [];
  const problems = [];
  for (let id = to; id >= from; id--) {
    const batch = await patiently(() => client.readContract({ address: REGISTRY, abi: ABI, functionName: 'getBatch', args: [id] }));
    const document = await fetchDocument(batch.uri);
    const leaves = document.scans.map((entry) => leafOf(entry, document.engineVersion));
    const root = rootOf(leaves);
    if (root.toLowerCase() !== batch.root.toLowerCase()) problems.push(`batch ${id}: recomputed root ${root} is not the root on chain ${batch.root}`);
    if (document.scans.length !== Number(batch.count)) problems.push(`batch ${id}: ${document.scans.length} entries, the chain says ${batch.count}`);
    if (Number(document.engineVersion) !== Number(batch.engineVersion)) problems.push(`batch ${id}: engine ${document.engineVersion} in the document, ${batch.engineVersion} on chain`);

    // The events of this batch, from the block it was committed in.
    const events = await patiently(() =>
      client.getLogs({ address: REGISTRY, event: ASSET_SCANNED, args: { batchId: id }, fromBlock: batch.committedBlock, toBlock: batch.committedBlock }),
    );
    const shown = document.scans.filter((entry) => ((BigInt(entry.flags) >> WITHHELD_BIT) & 1n) === 0n);
    const key = (e) => [e.chainKey, e.assetId, e.overallTrust, e.confidence, e.flags, e.scannedAtBlock].map((v) => String(v).toLowerCase()).join(',');
    const expected = new Map();
    for (const entry of shown) expected.set(key(entry), (expected.get(key(entry)) ?? 0) + 1);
    for (const event of events) {
      const k = key(event.args);
      if (!expected.get(k)) problems.push(`batch ${id}: event for ${event.args.assetId} matches no entry of the document`);
      else expected.set(k, expected.get(k) - 1);
    }
    for (const [k, left] of expected) if (left > 0) problems.push(`batch ${id}: document entry ${k} has no event`);

    for (const entry of shown) {
      rows.push(
        [id, entry.chainKey, entry.assetId, entry.overallTrust, entry.confidence, entry.flags, entry.scannedAtBlock]
          .map((value) => String(value).toLowerCase())
          .join(','),
      );
    }
    process.stderr.write(`batch ${id}: ${document.scans.length} entries, ${events.length} events, root ${root === batch.root.toLowerCase() || root.toLowerCase() === batch.root.toLowerCase() ? 'matches' : 'DIFFERS'}\n`);
  }

  await writeFile(out, ['batch_id,chain_key,asset_id,overall_trust,confidence,flags,scanned_at_block', ...rows].join('\n') + '\n');
  process.stderr.write(`${rows.length} rows written to ${out}\n`);
  if (problems.length > 0) {
    process.stderr.write(problems.join('\n') + '\n');
    process.exit(2);
  }
  process.stderr.write('every root, count, engine version and event matched\n');
}

main().catch((error) => {
  process.stderr.write(String(error?.stack ?? error) + '\n');
  process.exit(1);
});
