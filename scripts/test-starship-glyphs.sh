#!/usr/bin/env bash
# test-starship-glyphs.sh — guard harmon-init's OWN starship prompt against a
# repeat of harmon-init#535.
#
# The prompt shipped in .devcontainer/config/starship.toml is a powerline
# design: every segment transition is a Nerd Font separator (U+E0B0 and
# friends) and every OS/language marker is a private-use-area icon. Those
# codepoints were lost to a paste before the file first landed and nothing
# noticed across two commits, because a config stripped of them still parses
# as valid TOML. Only an explicit check catches it.
#
# This lives in a ROOT-ONLY script on purpose. The obvious home looks like
# scripts/devcontainer-assert.sh, but that file is a verbatim twin: it renders
# into every generated repo with devcontainer=true and runs there via
# `task test:devcontainer:permissions` in CI. A consumer who legitimately
# replaces this powerline theme with a plain prompt has no U+E0B0 at all, and
# a shipped assertion would fail their CI on a perfectly valid config. The
# glyphs are harmon-init's choice of theme, not an invariant we may impose
# downstream — so the check guards our two copies and ships to nobody.
set -euo pipefail
cd "$(dirname "$0")/.."

# U+E0B0 as its UTF-8 bytes in octal: macOS bash 3.2 has no \uXXXX inside
# $'…' and BSD grep has no -P, so the literal escape is the portable spelling.
SEP=$'\356\202\260'

# Both harmon-init copies: the root dogfood and the template source it is a
# verbatim twin of. test:dogfood-parity proves they are identical, but two
# identically-stripped files would pass that and fail this.
FILES="
.devcontainer/config/starship.toml
template/[% if devcontainer %].devcontainer[% endif %]/config/starship.toml
"

fail=0
checked=0
while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ ! -f "$file" ]; then
        echo "FAIL: expected starship config is missing: ${file}" >&2
        fail=1
        continue
    fi
    checked=$((checked + 1))
    if ! LC_ALL=C grep -q "$SEP" "$file"; then
        echo "FAIL: ${file} has no U+E0B0 powerline separators — the Nerd Font glyphs were stripped (harmon-init#535)" >&2
        echo "  restore from the harmon-dotfiles reference (dot_config/starship.toml) rather than retyping them" >&2
        fail=1
    fi
done <<EOF
$FILES
EOF

if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "starship glyphs OK: ${checked} config(s) retain their powerline separators"
