#!/usr/bin/env bash
# Popup pane body: render one bead plus its dependency tree, with every bead ID
# in the output wrapped as an OSC 8 hyperlink so the popup is recursive —
# Ctrl-click a blocker to jump straight to it.
set -uo pipefail

STATE_DIR="${TMPDIR:-/tmp}/beads-popover"
GEN_FILE="$STATE_DIR/generation"
mkdir -p "$STATE_DIR" 2>/dev/null

# Wrap bare bead IDs in OSC 8 links pointing back at our own handler.
#
# The suffix must contain a digit and stay short, otherwise ordinary hyphenated
# English ("self-contained", "well-known") gets linkified into nonsense. The
# lookbehind skips IDs already inside a URL so existing links survive intact.
linkify() {
  perl -pe '
    s{(?<![\w/.-])([a-z][a-z0-9_]*-(?=[a-z0-9]{2,8}(?![\w-]))[a-z]*[0-9][a-z0-9]*)(?![\w-])}
     {\e]8;;https://bead.invalid/$1\e\\$1\e]8;;\e\\}gi
  '
}

hr() { printf '\033[2m%*s\033[0m\n' "${COLUMNS:-72}" '' | tr ' ' '─'; }

render() {
  if [[ -n "${BEAD_ERROR:-}" ]]; then
    printf '\033[1;31mBeads popover\033[0m\n\n  %s\n' "$BEAD_ERROR"
    return
  fi

  local bead_id="${BEAD_ID:-}" out tree
  if [[ -z "$bead_id" ]]; then
    printf '\033[1;31mBEAD_ID not set\033[0m\n'; return
  fi
  if ! command -v bd >/dev/null 2>&1; then
    printf '\033[1;31mbd not found on PATH\033[0m\n'; return
  fi

  # bd writes "no beads database found" to stderr and exits non-zero when the
  # cwd is outside a beads repo — the single most likely failure, so name it.
  if ! out=$(bd show "$bead_id" 2>&1); then
    printf '\033[1;31mCould not read %s\033[0m\n\n%s\n' "$bead_id" "$out"
    printf '\n\033[2mcwd: %s\033[0m\n' "${BEAD_CWD:-$PWD}"
    return
  fi

  printf '%s\n' "$out" | linkify
  if tree=$(bd dep tree "$bead_id" 2>/dev/null) && [[ -n "${tree//[[:space:]]/}" ]]; then
    hr
    printf '%s\n' "$tree" | linkify
  fi
}

render
printf '\n\033[2m— any key to close · Ctrl-click an ID to follow it —\033[0m'

# Popups are session singletons: while this one lives, no other can open. So
# watch the generation counter and step aside when a newer click arrives,
# instead of making that click fail with "popup already open".
mine=$(cat "$GEN_FILE" 2>/dev/null || echo 0)
while :; do
  read -rsn1 -t 0.2 && exit 0
  [[ "$(cat "$GEN_FILE" 2>/dev/null || echo 0)" != "$mine" ]] && exit 0
done
