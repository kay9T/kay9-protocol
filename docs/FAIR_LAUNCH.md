# KAY9 Fair Launch

KAY9 launches through the audited Uniswap Liquidity Launcher stack on Robinhood Chain: a Continuous Clearing Auction (CCA) for price discovery, followed by automatic migration of the proceeds into a Uniswap v4 pool. KAY9 does not implement its own bonding curve or sale contract. The only KAY9 code in the path is `KAY9Genesis`, which supplies the tokens and pins the parameters, and `KAY9LiquidityLock`, which makes the resulting liquidity permanent.

## What is fair about it

| Rule | How it is enforced |
|---|---|
| No presale, no private allocation | The only supply outside the 91 % launch allocation is the declared 9 % team allocation in `KAY9TeamVesting`. Genesis holds the rest and can only send it to the launcher. |
| No whitelist | `KAY9Genesis.launch()` sets the CCA `validationHook` to `address(0)` and reverts otherwise. |
| No privileged creator purchase, no dev pre-buy | The team receives tokens only through vesting. Every bid, including any team bid, is a public `submitBid` transaction at the same clearing price as everyone else. |
| No fake wallets, wash trading, bundled buys, artificial volume | None is built, none is scripted, and the KAY9 audit engine flags exactly these patterns on other tokens. Any such behaviour by insiders would be visible on-chain and contradict the project's purpose. |
| Uniform pricing | CCA clears every block at one price; bids above the clearing price pay the clearing price, not their maximum. |
| Refund if the auction fails | If less than `requiredCurrencyRaised` is raised, bidders withdraw their full ETH through `exitBid` and the tokens return to Genesis. |

## Parameters

Deployment parameters are supplied by the owner at launch time, echoed on-chain in the `LaunchConfigured` event, and displayed on kay9.io before the auction starts. Reference values from the brief:

| Parameter | Reference | Notes |
|---|---|---|
| Auction supply | 455,000,000 KAY9 | constant, enforced |
| Liquidity reserve | 455,000,000 KAY9 | constant, enforced |
| Raise currency | native ETH | enforced |
| Duration | 4 hours ≈ 144,000 blocks | Counted on the chain's own clock (`ArbSys.arbBlockNumber()`, ≈ 0.10 s), which is what the auction reads; Genesis enforces 36,000–864,000 blocks, one hour to one day, on the same clock |
| Floor / reference FDV | about USD 1,000 | owner parameter; implied floor price = FDV ÷ 1,000,000,000 |
| Graduation / target FDV | about USD 10,000 | owner parameter; expressed on-chain as `requiredCurrencyRaised` in ETH |
| CCA price tick | 1 % of the floor price | Uniswap SDK default |
| Emission schedule | 12 convex steps + 30 % in the final block | Uniswap SDK default (`deriveConvexAuctionSteps`) |
| LP allocation | 100 % of raised ETH | enforced |
| Pool | Uniswap v4, fee 1 % (10000), tick spacing 200, hook = Uniswap's canonical `InitializerHook` (gates initialization only; no swap logic, no hookData) | enforced; the hook makes the pool key impossible to squat before migration |
| Migration | anyone, after `migrationBlock` | enforced `migrationBlock > endBlock` |

FDV is always computed over the full 1,000,000,000 supply. The floor price in the CCA's Q96 format is `floorFdvWei × 2⁹⁶ ÷ 10²⁷` (ETH-wei per KAY9-wei), and the USD figures depend on the ETH/USD rate at configuration time, which the launch script reads from the Chainlink feed and prints. The owner confirms the resulting implied prices before signing.

## Sequence

1. **Configure and launch (owner signs).** `KAY9Genesis.launch(params)` validates every invariant, deposits 910 M KAY9 into the launcher, and the launcher hands them to `LBPStrategy`, which deploys the CCA with 455 M and keeps 455 M for liquidity.
2. **Auction.** Bidders call `submitBid(maxPriceQ96, amount, owner, hookData)` with ETH on the CCA contract, from kay9.io, from the Uniswap app's auctions tab, or from any tool. The clearing price rises as demand exceeds the scheduled supply. Bids below the clearing price can exit and reclaim ETH. A bid whose max price ends exactly *at* the final clearing price — where most demand settles — cannot use `exitBid` (`CannotExitBid`); it leaves through `exitPartiallyFilledBid(bidId, lastFullyFilledCheckpointBlock, 0)` after the end block, with the block of the last checkpoint whose clearing price was still below the bid's max. kay9.io computes that hint from the `CheckpointUpdated` log; the Uniswap app does the same.
3. **End and claim.** After `endBlock`, the final checkpoint fixes the clearing price. Winners claim KAY9 after `claimBlock`.
4. **Migration (anyone).** `LBPStrategy.migrate(auction)` sweeps the ETH, initializes the pool at the clearing price, mints the full-range position, and sends the LP NFT to `KAY9LiquidityLock`.
5. **Lock (anyone).** `KAY9LiquidityLock.lock(tokenId)` registers the creator-fee beneficiary and transfers the NFT into `FeeSplitter`, permanently.
6. **Settle (anyone).** `KAY9Genesis.settle()` sweeps unsold KAY9 from the auction and any returned reserve, adds them as single-sided liquidity above both the market price and the auction's clearing price, locks that position too, and burns dust.

## Proceeds

All ETH raised goes to liquidity. The protocol fee of the CCA factory on Robinhood Chain is currently zero (`protocolFeeController = 0x0`). Trading fees on the pool are split by the canonical `FeeSplitter`: 40 % of native-side fees to the holder of the beneficiary NFT, which is the owner's creator-fee address, and 60 % of native-side and 100 % of KAY9-side fees compounded back into the position. This is the only revenue stream anywhere in KAY9; the audit protocol has none, because nobody pays for an audit. The website never describes this as "the creator receives 1 % of every trade".

## Failure and recovery

- **Not graduated:** bidders refund themselves; 455 M returns to Genesis via `sweepUnsoldTokens`; the strategy's recovery returns the 455 M reserve to Genesis; Genesis blocks a new launch for 48 hours and then the owner may `launch()` again with new pricing under the same invariants.
- **Graduated but migration failed:** the strategy returns the ETH and the reserve to Genesis. `KAY9Genesis.recover()` is permissionless and creates the pool position itself at the auction's final clearing price, then locks it. ETH cannot leave Genesis by any other path.

## Where to watch

- Auction contract: address emitted in `LaunchConfigured` / `Launched`.
- Uniswap app: Explore → Auctions (Robinhood Chain).
- kay9.io/launch: live clearing price, raised versus required, your bids, migration and lock status.
