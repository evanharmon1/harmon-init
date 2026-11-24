# Renovate preset publication

`renovate/default.json` contains the unconditional shared policy extracted from
`template/renovate.json.jinja`: the schedule and dashboard settings, common
regex managers, and common package rules. It retains the existing release-age,
no-automerge, grouping, and hold behavior. The template renders its full
configuration by default.

The later adoption must retain local rules for Copier answers and project types,
including skills sync, devcontainer, Node, Python, Ansible, and Terraform, as
well as root maintainer-specific policy. Preset rules precede local rules, and
later matching rules override earlier settings. The pilot restores the
formatter grouping after the local devcontainer rule and applies the lockfile
groups and major-update exceptions last, as in the inline policy.

Compatibility holds use Renovate's `description` field with `Reason:`,
`Upstream:`, `Remove when:`, and `Canary:` sections, separated by semicolons.
The removal condition names a test, and the canary is a public repository that
tries the removal first. Harmon-init is the Node and Astro canary: test the
candidate version in its image or rendered Node/Astro profiles before lifting a
hold. `task lint:renovate-holds` checks the records and shared hold parity. It
selects the config the way Renovate does: the first of `renovate.json`,
`renovate.jsonc`, `renovate.json5`, then the same three names under
`.github/`. It checks only `renovate.json` or `.github/renovate.json` and
fails closed when Renovate would read a `.jsonc` or `.json5` file first. The
TypeScript hold and the Node runtime hold (Node 24 across both runtime
extractions, from issue #2013) remain inline in the root and default render.
The default render applies the TypeScript hold only to Node projects. The
missing-binary exclusions stay root-local.

The strict Renovate configuration CI task validates the preset and root
`renovate.json` with the pinned `renovate-config-validator`, then validates the
rendered profile matrix. Validation of the preset alone does not prove that an
adopted configuration resolves to the same policy.

Roll out in this order:

1. A human merges the publication change and the maintainer makes a real release
   containing `renovate/default.json`.
2. Offer the released preset to eligible Node pilots, retain local exceptions,
   and test resolved-policy parity against the inline configuration.
3. Run three pilot repositories for two cycles and check for policy regressions
   before fleet adoption.

## Node pilot

Set `use_renovate_preset` to `true` for a `web-astro` or `web-app` project
participating in the pilot. The answer defaults off. The generated config
extends `github>evanharmon1/harmon-init//renovate/default#v5.21.0` and
includes the template-generated exceptions. It uses the project's existing
Renovate installation. The root and other project types use inline policy.

Opt in only if Renovate's resolved configuration for the repository matches
its effective inline policy. If they differ, keep `use_renovate_preset` off.
The parity test covers fresh template renders.

The released preset adds an unconditional TypeScript hold to non-Node
projects. In the root it also adds the Astro formatter note and overlaps
with the root's broader regex managers. These differences keep full
adoption open. The maintainer checks three pilot repositories over two
Renovate cycles before fleet adoption.

Advance the pin in a reviewed template change after verifying that the
public release tag contains the preset and the policy still passes parity
tests. The pilot config disables generic Renovate updates for this pin. If
Renovate cannot resolve the tagged preset, it cannot process the repository's
updates. Re-render with the answer off to return to inline policy.
