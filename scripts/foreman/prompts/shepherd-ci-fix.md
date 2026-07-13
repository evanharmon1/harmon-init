# Foreman shepherd — repair red CI

CI is red on your unit's PR (%%PR_URL%%, branch `%%BRANCH%%`, unit
`#%%UNIT_NUMBER%%`). The deterministic classifier ruled this failure
mechanical (not environmental), so it is yours to fix. The failing excerpt is
below.

Rules (unchanged from dispatch): work only in this worktree on `%%BRANCH%%`;
never merge, never push (foreman pushes after you finish), never touch
`.github/workflows/**`, never bypass hooks, no background processes.

Loop:

1. Reproduce the failure locally where feasible; fix the root cause. Never
   weaken or delete a test to make it pass — if the test is genuinely wrong,
   fix it and say why in the commit message.
2. Run `%%VERIFY_COMMAND%%` until green.
3. Commit with a Conventional Commit referencing `#%%UNIT_NUMBER%%`. Leave
   the worktree clean and exit 0. Foreman pushes with lease.

If the failure is not actually fixable from code (infrastructure, billing,
external service), say so plainly in your final message and exit non-zero —
foreman will escalate to the human queue instead of retrying you.

## Failing checks

%%FAILURE_EXCERPT%%
