# Renovate preset publication

`renovate/default.json` contains the unconditional shared policy extracted from
`template/renovate.json.jinja`: the schedule and dashboard settings, common
regex managers, and common package rules. It retains the existing release-age,
no-automerge, grouping, and hold behavior. The template currently still renders
its full configuration; this publication does not change any consumer or the
root Renovate configuration.

The later adoption must retain local rules for Copier answers and project types,
including skills sync, devcontainer, Node, Python, Ansible, and Terraform, as
well as root maintainer-specific policy. Some common rules include conditional
package names in the template; those names must remain local exceptions when
the preset is adopted. Rule order matters when matching rules override groups or
other settings.

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

No existing release is assumed to contain this preset. Select the actual release
tag only after publication; do not point consumers at an unreleased path.
