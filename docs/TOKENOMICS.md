# KAY9 Tokenomics

KAY9 has a fixed supply of **1,000,000,000 KAY9** (18 decimals), minted once in the constructor of `KAY9Token` and never again. There is no mint function, no owner, no pause, no blacklist, no transfer fee, no rebase, no reflection, and no proxy. `KAY9Token` inherits only OpenZeppelin `ERC20`, `ERC20Permit` and `ERC20Burnable`; the only way supply changes is downward, when a holder burns their own tokens. The audit protocol never burns anybody's KAY9: nothing is charged, so there is nothing to burn.

## Allocation

| Allocation | KAY9 | Share | Where it lives after genesis |
|---|---|---|---|
| Public fair auction | 455,000,000 | 45.5 % | The Continuous Clearing Auction contract, then bidders |
| Permanent liquidity reserve | 455,000,000 | 45.5 % | `LBPStrategy` until migration, then the Uniswap v4 pool, locked |
| Team | 90,000,000 | 9 % | `KAY9TeamVesting` |
| **Total** | **1,000,000,000** | **100 %** | |

The 91 % launch allocation (910,000,000 KAY9) is split exactly in half: 50 % of it is sold in the auction and 50 % of it is paired with the auction's ETH as liquidity. Expressed against total supply that is 45.5 % + 45.5 %.

`KAY9Genesis` receives the whole supply in the token constructor, immediately transfers 90,000,000 to `KAY9TeamVesting`, and keeps 910,000,000 that can only leave through the Uniswap Liquidity Launcher path enforced by `launch()`. The genesis contract has no withdraw function.

## Team schedule

The team allocation is released in three steps by `KAY9TeamVesting`. The three timestamps are immutable constructor arguments computed as exact UTC calendar dates from the TGE date (same day of month and time; if the target month is shorter, the last day of that month is used). They are never "180 days". With the owner's target TGE of 10 November 2026, the tranches fall on 10 May 2027 and 10 November 2027 at the TGE's time of day; the exact timestamps are printed by `ComputeVesting.s.sol` before deployment and burned into the contract.

| Step | KAY9 | Share of supply | Cumulative | Unlock |
|---|---|---|---|---|
| 1 | 10,000,000 | 1 % | 1 % | TGE |
| 2 | 40,000,000 | 4 % | 5 % | TGE + 6 calendar months |
| 3 | 40,000,000 | 4 % | 9 % | TGE + 12 calendar months |

`release()` is permissionless: anyone can trigger a release and the tokens always go to the beneficiary. Nothing can accelerate, modify, or recover the locked tokens. The beneficiary can transfer the beneficiary role to another wallet (for key rotation); that is the only mutable value in the contract.

## Liquidity model

- The auction raises native ETH. 100 % of the raised ETH (the `lpAllocationSchedule` is a single bracket at 100 %) plus the 455,000,000 KAY9 reserve are migrated into a Uniswap v4 pool at the auction's final clearing price as one full-range position.
- The pool's LP fee is **1 %** (`fee = 10000`, tick spacing 200). This is a pool fee paid by traders to the liquidity position, not a token tax.
- The LP NFT is delivered to `KAY9LiquidityLock`, which registers the project's creator-fee beneficiary and then transfers the NFT into Uniswap's `FeeSplitter`, a contract with no admin and no withdrawal path. **No one, including the team, can withdraw the liquidity principal.**
- Fee accounting, as deployed on Robinhood Chain in `FeeSplitter 0xeFF166AAf189323c58dc27eD1206EB2C37FaACDf`: of the native-ETH side of collected fees, 40 % is claimable by the beneficiary NFT holder and 60 % is compounded back into the position; 100 % of the KAY9 side is compounded back into the position. Anyone can call `collectFees`.
- Unsold auction tokens and any unused part of the reserve are settled by the permissionless `KAY9Genesis.settle()`: they become a single-sided KAY9 position just above the market price and never below the auction's clearing price, locked the same way. Amounts under 1,000 KAY9 are burned. Unsold tokens never become a team allocation.

## What KAY9 is for

KAY9's utility is **unlocking access by locking it, not paying fees**. There is no price per audit,
no fee, no escrow, no treasury share and no burn. To use the deep or forensic analysis tiers you
deposit KAY9 into `KAY9AccessVault`, you keep it, and at the end of the period you take all of it
back. `docs/ACCESS_MODEL.md` is the specification.

| Tier | What it requires | Period | Allowance per period |
|---|---|---|---|
| Basic scan | nothing: no lock, no wallet, no KAY9 | — | unlimited, and it runs in the visitor's own browser |
| Deep | lock 5,000 KAY9 | 30 days | 4 deep audits |
| Forensic | lock 10,000 KAY9 | 30 days | 1 forensic **and** 4 deep audits |

The amounts are fixed in KAY9, held in the vault as `requirementOf[tier]` and changeable only
through the 48 hour timelock, within on-chain bounds (one KAY9 to 10,000,000 KAY9, forensic never
below deep). A period copies the requirement when it opens and keeps it; a later change applies
only to periods opened or renewed afterwards, and `unlock` returns exactly what was locked. There
is no price oracle in the access path, so the dollar value of a lock moves with the token until the
owner adjusts the number, and every adjustment is public for 48 hours before it applies.

**Nothing flows.** No KAY9 moves from a requester to an auditor, to a treasury, or to a burn
address. Any diagram showing such a flow describes a model this protocol does not implement and is
wrong. The only two movements the vault ever makes are the depositor's tokens in, and the
depositor's tokens out.

**No yield.** The lock pays no annual percentage yield, no reward, no emission and no share of
anything. The vault mints nothing, receives nothing beyond the principal it will return, and holds
no slashing mechanism. `totalLocked` is the sum of every principal it is holding for somebody else.

Two consequences worth stating, because they are the reasons the model was chosen:

- **The analyst is not on the payroll of the analysed.** A requester gives KAY9 to nobody, so no
  score can be a payment for anything. A token creator may request an audit of their own token and
  gets the identical engine; the report records that the requester declared itself the creator and
  labels the declaration unverified unless the auditors establish the requester is the deployer
  on-chain.
- **Nothing in KAY9 rewards volume.** No party earns more by publishing more audits, so there is no
  incentive to publish more of them rather than better ones. The per-period allowance exists only to
  bound the cost of analysis that is genuinely expensive to run.

Demand for KAY9 therefore comes from wanting continuing access to the deeper tiers, and the token
that provides that access is not consumed by using it.

## Circulating supply

Circulating supply as displayed on kay9.io is computed on-chain as `totalSupply − balanceOf(KAY9TeamVesting) − balanceOf(KAY9Genesis) − balanceOf(auction contract during the auction)`. Tokens inside the locked liquidity position are counted as circulating because they are tradable.

KAY9 held by `KAY9AccessVault` is **not** subtracted, and is shown separately as `totalLocked`. It is not the protocol's: every unit of it is a depositor's principal that returns in full at the end of a thirty day period. Subtracting it would make the headline supply figure move with how many people currently hold access rather than with how the supply is distributed, which is not what the number is for. Showing it separately says the useful thing — how much KAY9 is committed to access right now — without pretending the tokens have left.
