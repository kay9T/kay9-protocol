# Model reviews of the launch path

Gate 6 of the launch readiness checklist asks for the launch-path contracts (`KAY9Genesis`,
`KAY9Token`, `KAY9TeamVesting`, `KAY9LiquidityLock`) to be reviewed by at least two large language
models from **different families**, at the commit that will be deployed, with every review
published in full and every finding either fixed or accepted in writing.

**This is not a professional audit.** No firm is accountable for these reviews and nobody carries
liability for a miss. KAY9 is never described as "audited" or "verified safe" because of them. What
may be said is exactly what happened: reviewed by named models, on a date, with the output here.

Every review is given the same prompt, published beside them, so a reader can see what each model
was asked. The two reviews come from different model families, each starts in a fresh session with
no context on the project, and each reads only the tagged commit. The code itself was written with
many model families, so none is independent of it by authorship; on 2026-09-23 the owner decided
that the second review may therefore come from Anthropic, as long as it is a different family from
the first (see gate 6 of the launch readiness checklist).

| Date | Model | Family | Commit | Findings | Status |
|---|---|---|---|---|---|
| 2026-09-23 | GPT-5.6 Sol, reasoning effort high | OpenAI | `launch-review-1` (`db65339b`), verified at `launch-review-2` (`a327a830`) | 2 medium, 1 low | two closed, one narrowed to one wei of rounding; final verification at `launch-review-4` raised R-01, fixed at `launch-review-5` and confirmed closed there; [the whole review thread, hosted by ChatGPT](https://chatgpt.com/share/6ab3eea8-69f8-83ec-8be5-17daaf127312); [the review, verbatim, with the disposition of each finding](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/2026-09-23-openai-gpt-5.6-sol.md) |
| 2026-09-23 | Claude Fable 5.1 | Anthropic | `launch-review-3` (`8dde1aa0`) | 2 medium, 4 low, 6 informational | nine fixed at `launch-review-4`, two accepted, one rejected with a measurement; verified at `launch-review-4` by Claude Opus 5.5 (Fable had reached its usage limit): six closed, three narrowed and accepted in writing; the final change confirmed at `launch-review-5`; [the review, verbatim, with the disposition of each finding](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/2026-09-23-anthropic-claude-fable-5.1.md) |

The prompt: [LAUNCH_PATH_REVIEW_PROMPT.md](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/LAUNCH_PATH_REVIEW_PROMPT.md).

A fix that changes a contract moves the commit under review, and every review then runs again at
the new commit. That is why the table names the tag each review was run at.

## Where gate 6 stands

Both reviews ran on the launch path, both were verified on the fixes, and both confirmed the final
commit, **`launch-review-5`** (`41e30ecd552a52c2086d7cee055e3a4a030762ea`), which is the commit to
deploy. Every finding is fixed or accepted in writing, with the reason. What is accepted, in short:
an actor who calls Uniswap's strategy directly and gives the vault half the raise can still send a
good launch into the recovery path, at the cost of that half, locked into KAY9 liquidity for good,
and for no return; the vault can keep at most one wei of rounding; and the claim that nobody can
profit from forcing recovery is argued, not proved.

The owner accepted these and closed gate 6 for the launch path on 2026-09-25. The watchdog stack's
reviews are a separate part of the gate and are still to run.

## The watchdog stack

The watchdog contracts (`KAY9AuditorRegistry`, `KAY9AuditHub`, `KAY9Registry`, `KAY9ScanRegistry`)
and `DeployWatchdog.s.sol` go to mainnet about a month before the token and are as immutable, so
gate 6 asks the same of them: two model families, at the commit to be deployed, with every finding
fixed or accepted in writing. The prompt is
[WATCHDOG_REVIEW_PROMPT.md](WATCHDOG_REVIEW_PROMPT.md).

| Date | Model | Family | Commit | Findings | Status |
|---|---|---|---|---|---|
| 2026-09-25 | GPT-5.6 Sol | OpenAI | `watchdog-review-1` (`c38dd247`) | 3 medium, 7 low | six fixed, four accepted in writing; verified at `watchdog-review-2`: seven closed, three narrowed, four new findings, all fixed at `watchdog-review-3`, confirmed for deployment there; its last low finding fixed at `watchdog-review-4` and that commit confirmed; [the review, verbatim, with the disposition of each finding](2026-09-25-watchdog-openai-gpt-5.6-sol.md) |
| 2026-09-25 | Claude Opus 5.5 (Fable 5.1 had reached its usage limit) | Anthropic | `watchdog-review-1` (`c38dd247`) | 2 medium, 4 low, 3 informational | four fixed, three fixed in part, two accepted in writing; verified at `watchdog-review-2`: three closed, the rest narrowed or accepted, three new findings, all fixed at `watchdog-review-3` and confirmed for deployment there; [the review, verbatim, with the disposition of each finding](2026-09-25-watchdog-anthropic-claude-opus-5.5.md) |

Both reviews found that one key could move a headline score, that the quorum could quietly shrink
or stall after auditor rotation, and that the deploying key kept power for 48 hours. Those are
fixed. The owner closed gate 6 for the watchdog stack on 2026-09-25. **The commit to deploy is `watchdog-review-4`** (`a71cb5c6928ffdc45b78dccb398180972f14f0e4`). Both families
confirmed it for deployment; Anthropic's confirmation is of `watchdog-review-3`, and the one
contract change after it (R3-01, the dispute event's agreement count) was confirmed by OpenAI and
has its own regression test. Slither at `watchdog-review-4` found nothing new.

What is accepted: `latestScan` is the scanner's own index rather than a value proven against
the batch root, `scannedAtBlock` is the scanner's statement, and removing an auditor still takes the
48-hour timelock.

## Independent copies

Each review file was captured by the Internet Archive's Wayback Machine at the commit that carries
its final confirmation, so its text can be checked against a copy nobody on the project controls:

- [OpenAI GPT-5.6 Sol review](https://web.archive.org/web/20260923170031/https://github.com/kay9T/kay9-protocol/blob/8f91c30f1d8a9f53f7985998d687de7cbdd31ef9/docs/reviews/2026-09-23-openai-gpt-5.6-sol.md)
- [Anthropic Claude Fable 5.1 review](https://web.archive.org/web/20260923170226/https://github.com/kay9T/kay9-protocol/blob/8f91c30f1d8a9f53f7985998d687de7cbdd31ef9/docs/reviews/2026-09-23-anthropic-claude-fable-5.1.md)
- [This index](https://web.archive.org/web/20260923170433/https://github.com/kay9T/kay9-protocol/blob/8f91c30f1d8a9f53f7985998d687de7cbdd31ef9/docs/reviews/README.md)
- [The prompt](https://web.archive.org/web/20260923164313/https://github.com/kay9T/kay9-protocol/blob/41e30ecd552a52c2086d7cee055e3a4a030762ea/docs/reviews/LAUNCH_PATH_REVIEW_PROMPT.md)

The ChatGPT share link is hosted by OpenAI. The Wayback Machine cannot render it (the page is built
in the browser), so it has no archived copy yet.
