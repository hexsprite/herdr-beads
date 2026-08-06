#!/usr/bin/env bash
# Detail pane body: render one bead plus its dependency tree, with every bead ID
# wrapped as an OSC 8 hyperlink so the pane is recursive — Ctrl-click a blocker
# to jump straight to it.
#
# The pane is long-lived. It watches a state file and re-renders in place when a
# new bead is selected, so clicking a link inside this pane replaces its own
# contents instead of spawning another pane.
set -uo pipefail

STATE_DIR="${TMPDIR:-/tmp}/beads-popover"
CURRENT="$STATE_DIR/current"
mkdir -p "$STATE_DIR" 2>/dev/null

# Wrap bare bead IDs in OSC 8 links pointing back at our own handler.
#
# The suffix must contain a digit and stay short, otherwise ordinary hyphenated
# English ("self-contained", "well-known") gets linkified into nonsense. The
# lookbehind skips IDs already inside a URL so existing links survive intact.
linkify() {
  perl -pe '
    s{(?<![\w/.-])([a-z][a-z0-9_]*(?:-[a-z][a-z0-9_]*)*-(?=[a-z0-9]{2,8}(?:\.[0-9]+)?(?![\w-]))[a-z0-9]*[0-9][a-z0-9]*(?:\.[0-9]+)?)(?![\w-])}
     {\e]8;;https://bead.invalid/$1\e\\$1\e]8;;\e\\}gi
  '
}

hr() { printf '\033[2m%*s\033[0m\n' "${COLUMNS:-72}" '' | tr ' ' '─'; }

# State file layout: line 1 is the bead ID, line 2 its repo, anything after is
# an error message. Keeping the error out of band avoids quoting a multi-line
# message through the same line-oriented format.
render() {
  local id="$1" cwd="$2" err="$3" out tree

  if [[ -n "$err" ]]; then
    printf '\033[1;31mBeads popover\033[0m\n\n%s\n' "$err"
    return
  fi
  if [[ -z "$id" ]]; then
    printf '\033[1;31mNo bead selected\033[0m\n'; return
  fi
  if ! command -v bd >/dev/null 2>&1; then
    printf '\033[1;31mbd not found on PATH\033[0m\n'; return
  fi

  # bd writes "no beads database found" to stderr and exits non-zero when the
  # cwd is outside a beads repo — the single most likely failure, so name it.
  if ! out=$(cd "${cwd:-$PWD}" 2>/dev/null && bd show "$id" 2>&1); then
    printf '\033[1;31mCould not read %s\033[0m\n\n%s\n' "$id" "$out"
    printf '\n\033[2mcwd: %s\033[0m\n' "${cwd:-$PWD}"
    return
  fi

  printf '%s\n' "$out" | linkify
  if tree=$( cd "${cwd:-$PWD}" && bd dep tree "$id" 2>/dev/null ) \
     && [[ -n "${tree//[[:space:]]/}" ]]; then
    hr
    printf '%s\n' "$tree" | linkify
  fi
}

draw() {
  local id cwd err
  id=$(sed -n '1p' "$CURRENT" 2>/dev/null)
  cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
  err=$(sed -n '3,$p' "$CURRENT" 2>/dev/null)

  printf '\033[H\033[2J'
  render "$id" "$cwd" "$err"
  printf '\n\033[2m— any key to close · Ctrl-click an ID to follow it —\033[0m'
}

# Seed from the environment on first launch so the pane has content before the
# state file is consulted.
if [[ ! -s "$CURRENT" && -n "${BEAD_ID:-}" ]]; then
  printf '%s\n%s\n' "$BEAD_ID" "${BEAD_CWD:-$PWD}" >"$CURRENT"
fi

last=""
while :; do
  now=$(cat "$CURRENT" 2>/dev/null)
  if [[ "$now" != "$last" ]]; then
    last="$now"
    draw
  fi
  # Any keystroke closes the pane; otherwise poll for a new selection.
  read -rsn1 -t 0.2 && exit 0
done
