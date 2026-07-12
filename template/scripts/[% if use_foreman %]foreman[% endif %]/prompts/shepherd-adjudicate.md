# Foreman shepherd — adjudicate review findings

Review bots left unresolved threads on your unit's PR (%%PR_URL%%, branch
`%%BRANCH%%`, unit `#%%UNIT_NUMBER%%`). Adjudicate EVERY thread listed below.
You know the spec; bots don't always — blanket-accepting is prohibited, and
so is blanket-dismissing.

Rules: work only in this worktree on `%%BRANCH%%`; never merge; never push
(foreman pushes); never edit or delete anyone else's comments; never touch
`.github/workflows/**`.

For each thread, exactly one disposition:

- **Apply** — the finding is right: fix it, commit (Conventional Commit
  referencing `#%%UNIT_NUMBER%%`), reply to the thread with a one-line
  `applied in <short-sha>` note, and resolve the thread.
- **Decline with reasoning** — the finding is wrong or out of scope: reply
  with brief technical reasoning. Deterministic facts beat bot speculation —
  cite the passing typecheck, the spec text, the API docs. Then resolve the
  thread.

To reply to a specific review thread use:
`gh api graphql -f query='mutation { addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:"<id>", body:"..."}) { comment { id } } }'`
and to resolve it:
`gh api graphql -f query='mutation { resolveReviewThread(input:{threadId:"<id>"}) { thread { isResolved } } }'`

After all threads: if you made commits, run `%%VERIFY_COMMAND%%` until green.
Leave the worktree clean and exit 0. Foreman verifies thread completeness
deterministically afterwards — an undispositioned thread means this run
failed.

## Unresolved threads

%%THREADS%%
