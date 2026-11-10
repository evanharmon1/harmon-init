# Renovate preset publication

`renovate/default.json` contains the unconditional shared policy extracted from
`template/renovate.json.jinja`: the schedule and dashboard settings, common
regex managers, and common package rules. It retains the existing release-age,
no-automerge, grouping, and hold behavior. The template currently still renders
its full configuration; this publication does not change any consumer or the
root Renovate configuration.

The later adoption must retain local rules for Copier answers and project types,
including skills sync, devcontainer, Node, Python, Ansible, and Terraform, as
well as root maintainer-specific policy. Preset rules precede local rules, and
later matching rules override earlier settings. A consumer with a local npm
major/non-major split must re-declare its
complete formatter rule after that split: include `markdownlint-cli2` as well
as the optional formatter names selected by its answers. Otherwise the local
split can override the shared formatter grouping.

Compatibility holds use Renovate's `description` field with `Reason:`,
`Upstream:`, `Remove when:`, and `Canary:` sections, separated by semicolons.
The removal condition names a test, and the canary is a public repository that
tries the removal first. Harmon-init is the Node and Astro canary: test the
candidate version in its image or rendered Node/Astro profiles before lifting a
hold. `task lint:renovate-holds` checks the records and shared hold parity. It
reads the root `renovate.json` when that file exists and otherwise
`.github/renovate.json`; the root file wins when both exist because Renovate
reads it first. The TypeScript rule remains inline in root and template until preset adoption; the
Node Corepack constraint and missing-binary exclusions are root-local. Do not
copy the missing-binary exclusions into the shared preset.

The strict Renovate configuration CI task validates the preset and root
`renovate.json` with the pinned `renovate-config-validator`, then validates the
rendered profile matrix. Validation of the preset alone does not prove that an
adopted configuration resolves to the same policy.

Roll out in this order:

1. A human merges the publication change and the maintainer makes a real release
   containing `renovate/default.json`.
2. In a later adoption change, pin the root and template references to that
   released tag, retain local exceptions, and test resolved-policy parity for
   every rendered project profile against the existing policy.
3. Run three pilot repositories for two cycles and check for policy regressions
   before fleet adoption.

A future reference has the form
`github>evanharmon1/harmon-init//renovate/default#vX.Y.Z`. Replace `vX.Y.Z`
only with an actual released tag containing the preset. Release `v5.17.0` does
not yet contain it; select the tag only after publication.
