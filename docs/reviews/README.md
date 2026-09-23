# Model reviews of the launch path

Gate 6 of the launch readiness checklist asks for the launch-path contracts (`KAY9Genesis`,
`KAY9Token`, `KAY9TeamVesting`, `KAY9LiquidityLock`) to be reviewed by at least two large language
models from **different families**, at the commit that will be deployed, with every review
published in full and every finding either fixed or accepted in writing.

**This is not a professional audit.** No firm is accountable for these reviews and nobody carries
liability for a miss. KAY9 is never described as "audited" or "verified safe" because of them. What
may be said is exactly what happened: reviewed by named models, on a date, with the output here.

Every review is given the same prompt, published beside them, so a reader can see what each model
was asked. The second family is deliberately not Anthropic's: a Claude model wrote part of this
code, and a review by the same family is not a second opinion on it.

| Date | Model | Family | Commit | Findings | Status |
|---|---|---|---|---|---|
| 2026-09-23 | GPT-5.6 Sol, reasoning effort high | OpenAI | `launch-review-1` (`db65339b`), verified at `launch-review-2` (`a327a830`) | 2 medium, 1 low | two closed, one narrowed to one wei of rounding and fixed at `launch-review-3`; [the review, verbatim, with the disposition of each finding](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/2026-09-23-openai-gpt-5.6-sol.md) |
| pending | second family (not Anthropic) | | `launch-review-3` | | not yet run |

The prompt: [LAUNCH_PATH_REVIEW_PROMPT.md](https://github.com/kay9T/kay9-protocol/blob/main/docs/reviews/LAUNCH_PATH_REVIEW_PROMPT.md).

A fix that changes a contract moves the commit under review, and every review then runs again at
the new commit. That is why the table names the tag each review was run at.
