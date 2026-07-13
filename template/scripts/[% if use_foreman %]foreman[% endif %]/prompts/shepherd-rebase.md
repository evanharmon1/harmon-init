# Foreman shepherd — conflicted rebase

A sibling PR merged into `%%DEFAULT_BRANCH%%` and your unit's branch
`%%BRANCH%%` (PR %%PR_URL%%, unit `#%%UNIT_NUMBER%%`) now conflicts. A
`git merge-tree` dry run enumerated the conflicting paths below.

Rules: work only in this worktree; never merge PRs; never push (foreman
force-pushes with lease after verification); no `--no-verify`.

Procedure — rebase, never merge-main (one update mechanism):

1. `git fetch` is already done. Run
   `git rebase %%DEFAULT_BRANCH%%` against the remote-tracking ref foreman
   prepared, resolving each conflict **additively**: both sides' intent must
   survive. When in doubt, prefer keeping the other side's semantics and
   re-applying this branch's change on top.
2. Regenerated artifacts (lockfiles, codegen output, schema snapshots) must
   be regenerated via their tooling — never hand-merge generated files.
3. Run `%%VERIFY_COMMAND%%` until green.
4. Leave the worktree clean (rebase completed, nothing uncommitted) and
   exit 0.

If a conflict cannot be resolved without a behavior-changing decision the
spec does not settle, stop, explain the decision needed in your final
message, and exit non-zero — foreman escalates it.

## Conflicting paths (merge-tree dry run)

%%CONFLICTS%%
