## 1. Fix the early-return reconciliation

- [x] 1.1 In `.devcontainer/config/ensure-antigravity-cli.sh`'s
      system-binary-sufficient early return, remove `~/.local/bin/agy` when it
      is a dangling symlink or a symlink to an existing directory, leaving a
      regular file, a valid wrapper, or a symlink to an existing file
      untouched. Verify with `bash -n` and `shellcheck --severity=error`.
- [x] 1.2 Copy the identical change to the verbatim `template/` twin and
      verify `task test:dogfood-parity` reports the two files byte-identical.

## 2. Regression coverage

- [x] 2.1 Add fixtures to `scripts/test-bot-autonomy.sh` covering: a dangling
      symlink is removed; a symlink to an existing directory is removed; a
      previously-installed valid wrapper is preserved byte-for-byte; an
      arbitrary regular file is preserved; a symlink to an existing file is
      preserved (the negative case distinguishing "removes the two breaking
      shapes" from "removes every symlink"). Verify by running
      `bash scripts/test-bot-autonomy.sh` and confirming each new assertion
      fails when its corresponding guard is deliberately reverted
      (mutation-check), then passes again against the real fix.
- [x] 2.2 Add a fixture confirming a settings-apply failure inside
      `bot-autonomy/antigravity.sh`'s `cmd_apply` aborts before
      `install_wrapper` runs, so a prior valid wrapper survives untouched.
      Verify the fixture fails if `cmd_apply`'s ordering is swapped.
- [x] 2.3 Copy the identical test additions to the verbatim `template/` twin
      and verify `task test:dogfood-parity` reports the two files
      byte-identical.

## 3. Spec reconciliation

- [x] 3.1 Write this change's delta spec at
      `openspec/changes/agy-early-return/specs/devcontainer/bot-autonomy/spec.md`
      under `## MODIFIED Requirements`, collapsing the "exactly one of four
      states" launcher requirement to three states and updating the "Human
      dev profile is unaffected by construction" requirement's scenario that
      carries the state-(d) exception. Verify with `task spec:validate`.
- [x] 3.2 Apply the equivalent rewrite directly to the canonical
      `openspec/specs/devcontainer/bot-autonomy/spec.md` in this same PR (the
      launcher invariant and guide text must describe the fix's actual,
      already-shipped behavior rather than wait on a later archive step) and
      confirm no remaining reference to state (d) or `#1171` describes it as
      still open.
- [x] 3.3 Update `docs/guides/devcontainers.md` and its jinja `template/`
      twin to drop the state-(d)/`#1171` caveat, and verify
      `task test:dogfood-structure` still passes.

## 4. Verification

- [x] 4.1 Run `task spec:validate`, `task check`, `task verify`,
      `task test:bot-autonomy`, and `task security`, and confirm all are
      green.
- [x] 4.2 Tick this issue's `[CI]` acceptance criteria via
      `.claude/skills/track-work/assets/tick-criteria.sh` once each is
      independently verified against the code.

## 5. Challenge-round-3 ownership remediation (#1205/#1207)

- [x] 5.1 Remove launcher-derived authority to delete `agy-real`; require the
      installer's matching inode proof, while preserving interrupted managed
      install cleanup.
- [x] 5.2 Reuse an unowned exact-version `agy-real` executable or symlink
      without replacing it or publishing ownership metadata.
- [x] 5.3 Add focused fixtures for system-binary-only setup followed by an
      independent `agy-real`, exact-version symlink preservation, interrupted
      install cleanup, and canonical/delta requirement consistency.
- [x] 5.4 Reconcile this delta and the canonical bot-autonomy requirement to
      ownership-based disabled cleanup and verification semantics.
- [x] 5.5 Run `task test:bot-autonomy`, `task spec:validate`, `task check`,
      `task test:template:all`, `task verify`, and `task security:secrets`.

## 6. Challenge-round-4 legacy fixture remediation (#1205/#1207)

- [x] 6.1 Update the root/template devcontainer assertion fixture so a
      disabled rolling update removes the owned `agy` launcher but preserves a
      markerless pre-ownership-metadata `agy-real` byte-for-byte.
- [x] 6.2 Add the equivalent explicit scenario to the in-flight delta and
      canonical bot-autonomy spec without weakening the independent inode
      ownership invariant.
- [x] 6.3 Run the focused bot-autonomy and devcontainer assertions, then
      `task spec:validate`, `task check`, `task test:template:all`, `task
      verify`, and `task security:secrets`.

## 7. Challenge-round-5 ownership protocol remediation (#1205/#1207)

- [x] 7.1 Replace launcher-shape and same-inode ownership heuristics with
      independent per-path identity-and-content proofs for `agy` and
      `agy-real`; cleanup and disabled verification require those proofs.
- [x] 7.2 Publish executable and launcher generations through recoverable
      transactions, and add exact regression fixtures for an independent
      natural symlink, an in-place executable rewrite, and an interrupted
      old-to-new upgrade.
- [x] 7.3 Preserve all affected root/template twins and reconcile the
      canonical and in-flight bot-autonomy requirement with the new invariant.
- [x] 7.4 Run the focused bot-autonomy and devcontainer assertions, then
      `task spec:validate`, `task check`, `task test:template:all`, `task
      verify`, and `task security:secrets`.
