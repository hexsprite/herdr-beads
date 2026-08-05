#!/usr/bin/env bash
# Popup pane body: render one bead plus its dependency tree, with every bead ID
# in the output wrapped as an OSC 8 hyperlink so the popup is recursive —
# Ctrl-click a blocker to jump straight to it.
set -uo pipefail

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

if [[ -n "${BEAD_ERROR:-}" ]]; then
  printf '\033[1;31mBeads popover\033[0m\n\n  %s\n' "$BEAD_ERROR"
else
  bead_id="${BEAD_ID:-}"
  if [[ -z "$bead_id" ]]; then
    printf '\033[1;31mBEAD_ID not set\033[0m\n'
  elif ! command -v bd >/dev/null 2>&1; then
    printf '\033[1;31mbd not found on PATH\033[0m\n'
  else
    # bd writes "no beads database found" to stderr and exits non-zero when the
    # cwd is outside a beads repo — the single most likely failure, so name it.
    if ! out=$(bd show "$bead_id" 2>&1); then
      printf '\033[1;31mCould not read %s\033[0m\n\n%s\n' "$bead_id" "$out"
      printf '\n\033[2mcwd: %s\033[0m\n' "${BEAD_CWD:-$PWD}"
    else
      printf '%s\n' "$out" | linkify
      if tree=$(bd dep tree "$bead_id" 2>/dev/null) && [[ -n "${tree//[[:space:]]/}" ]]; then
        hr
        printf '%s\n' "$tree" | linkify
      fi
    fi
  fi
fi

printf '\n\033[2m— any key to close · Ctrl-click an ID to follow it —\033[0m'
read -rsn1
