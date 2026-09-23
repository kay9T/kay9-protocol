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
| 2026-09-23 | GPT-5.6 Sol, reasoning effort high | OpenAI | `launch-review-1` (`db65339b`), verified at `launch-review-2` (`a327a830`) | 2 medium, 1 low | two closed, one narrowed to one wei of rounding and fixed at `launch-review-3`; [the review, verbatim, with the disposition of each finding](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/2026-09-23-openai-gpt-5.6-sol.md) |
| 2026-09-23 | Claude Fable 5.1 | Anthropic | `launch-review-3` (`8dde1aa0`) | 2 medium, 4 low, 6 informational | nine fixed at `launch-review-4`, two accepted, one rejected with a measurement; [the review, verbatim, with the disposition of each finding](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/2026-09-23-anthropic-claude-fable-5.1.md) |

The prompt: [LAUNCH_PATH_REVIEW_PROMPT.md](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/LAUNCH_PATH_REVIEW_PROMPT.md).

A fix that changes a contract moves the commit under review, and every review then runs again at
the new commit. That is why the table names the tag each review was run at.
