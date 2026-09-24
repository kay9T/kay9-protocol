# Launch-path model review — the prompt

This is the exact text given to every model that reviews the launch path for gate 6 of
[`LAUNCH_READINESS.md`](../LAUNCH_READINESS.md). The same prompt goes to each model family, so the
reviews can be compared, and it is published with them so a reader can see what each model was
asked. Replace `<COMMIT>` with the full commit hash of the latest `launch-review-N` tag before sending.

A model that cannot read the repository is given the same code as an attached file instead,
generated from the commit with each file's git blob hash so it can be checked, and the **Commit**
paragraph below then says so. Nothing else in the prompt changes.

This is a model review, not a professional audit. No firm is accountable for it and nobody carries
liability for a miss. KAY9 is never described as "audited" or "verified safe" because of it.

---

You are reviewing the launch path of KAY9 for security and correctness. KAY9 is a fixed-supply
ERC-20 launched on Robinhood Chain (an Arbitrum Orbit chain, chain id 4663) through Uniswap's
Liquidity Launcher: a Continuous Clearing Auction sells 455,000,000 tokens, and the raise is paired
with another 455,000,000 as permanently locked Uniswap v4 liquidity. The code is public at
https://github.com/kay9T/kay9-protocol.

**Commit.** Review exactly commit `<COMMIT>`. Before anything else, quote the first two lines of
`src/KAY9Genesis.sol` at that commit so the reader knows which tree you read. If you cannot read
that commit, say so and stop. Do not review from memory or from another version.

**In scope**, and nothing else:

- `src/KAY9Genesis.sol`: the launch vault. Deploys the token, the team vesting and the liquidity
  lock; configures and runs the auction; settles leftover supply; recovers a failed migration; and
  allows a relaunch after a failed auction.
- `src/KAY9Token.sol`: the ERC-20. Fixed 1,000,000,000 supply minted once, no owner, no mint, no
  tax, no pause, no blacklist, no proxy.
- `src/KAY9TeamVesting.sol`: 90,000,000 tokens released in three tranches (1 % at TGE, +4 % at six
  calendar months, +4 % at twelve), nothing before the launch has settled.
- `src/KAY9LiquidityLock.sol`: the one-way door that hands the LP position to Uniswap's
  FeeSplitter, where it can never be withdrawn.
- The libraries these use: `src/libraries/AuctionPriceLib.sol`, `src/libraries/AuctionSteps.sol`,
  `src/libraries/TickRange.sol`, `src/libraries/CalendarMonths.sol`.
- The deployment and launch scripts, as far as they decide what these contracts are given:
  `script/Deploy.s.sol`, `script/Launch.s.sol`.

**Out of scope**: the audit protocol (`KAY9AccessVault`, `KAY9AuditHub`, `KAY9Registry`,
`KAY9AuditorRegistry`, `KAY9ScanRegistry`), the website and the off-chain services. The Uniswap
contracts under `lib/` are canonical third-party code; read them to understand how the launch
path calls them, but report a finding in them only if KAY9 uses them wrongly.

**The properties the design claims, which is what to try to break:**

1. The supply is fixed at 1,000,000,000 and can only ever shrink by a holder burning their own.
2. The split is exact: 455,000,000 auction, 455,000,000 liquidity reserve, 90,000,000 team vesting.
3. The owner supplies pricing and timing only. The owner cannot redirect the raise, change the
   pool (native ETH / KAY9, fee 10000 = 1 %, tick spacing 200, Uniswap's InitializerHook), change
   the position recipient, keep unsold supply, or move tokens or ETH anywhere except through the
   launch pipeline. There is no withdraw function.
4. Every wei of the raise ends in locked liquidity, except at most one wei of integer rounding
   left in the vault; unsold tokens become single-sided liquidity or are burned, and never reach
   the team.
5. If the auction does not reach its graduation threshold, every bidder gets their full ETH back,
   and a relaunch is possible only after the failure is marked and 48 hours have passed.
6. A graduated auction whose migration fails is rebuilt by `recover()` into a pool priced at the
   auction's clearing price, and nobody can profit from forcing that path.
7. The team receives nothing before the launch has settled, and after that exactly the calendar
   schedule fixed at deployment.
8. The LP position, once locked, can never be withdrawn by anyone, including the owner.
9. Every block number in the launch is read on the chain's own clock (`ArbSys.arbBlockNumber()`,
   about 0.1 s), never on `block.number`, which on this chain is the parent chain's height.

**What to return.** One markdown document and nothing outside it:

- Findings ranked most severe first. For each: a title, a severity, the file and line, a concrete
  failure scenario (who does what, in which order, and what is lost or wrongly allowed), and a
  suggested fix.
- A section listing each of the nine properties above as **holds**, **broken** or **could not
  conclude**, with the reason.
- A section stating plainly what you did **not** cover or could not verify.
- Your model name and version, as exactly as you know them.

Do not soften a finding and do not invent one. If you are unsure, say that you are unsure and why.
