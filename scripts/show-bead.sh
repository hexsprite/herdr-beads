#!/usr/bin/env bash
# Link-handler action: work out which bead was clicked and show it.
#
# Failures here are invisible by default — a click that does nothing looks
# identical to a click that missed. So every error path opens the pane anyway
# with the message inside it.
set -uo pipefail

PLUGIN_ID="beads.popover"
ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${TMPDIR:-/tmp}/beads-popover.pane"
HERDR="${HERDR_BIN_PATH:-herdr}"

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Herdr does not document the context payload and it has changed shape between
# versions, so always keep the last one on disk. Gitignored, one file, no growth.
[[ -n "$ctx" ]] && printf '%s\n' "$ctx" >"$ROOT/last-context.json" 2>/dev/null

have_jq() { command -v jq >/dev/null 2>&1; }

# Overlay panes stack, so retire the previous one before opening another.
# Without this, clicking through a dependency tree buries the screen in panes.
close_previous() {
  local prev
  [[ -r "$STATE" ]] && prev=$(<"$STATE") || prev=""
  if [[ -n "$prev" ]]; then
    # `plugin pane close` only knows panes opened since the plugin was last
    # linked, and reports plugin_pane_not_found for anything older. The generic
    # close has no such memory, so it is the one that actually always works.
    "$HERDR" plugin pane close "$prev" >/dev/null 2>&1
    "$HERDR" pane close "$prev" >/dev/null 2>&1
  fi
  : >"$STATE" 2>/dev/null
}

# Placement is deliberately "overlay", not "popup". Popups are session
# singletons: a second open fails outright with "popup already open", so every
# click after the first would silently do nothing. Overlays are real panes that
# can be replaced, which is what makes click-through work.
open_pane() {
  local cwd="$1"; shift
  local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint detail
              --placement overlay --focus)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  while (($#)); do args+=(--env "$1"); shift; done

  close_previous
  local out pane
  out=$("$HERDR" "${args[@]}" 2>&1)
  if have_jq; then
    pane=$(printf '%s' "$out" \
      | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
    [[ -n "$pane" ]] && printf '%s' "$pane" >"$STATE" 2>/dev/null
  fi
  exit 0
}

die() { open_pane "" "BEAD_ERROR=$1"; }

# Herdr sets this directly for link handlers (the mechanism official.browser
# uses). The context JSON is a fallback for other invocation paths.
url="${HERDR_PLUGIN_CLICKED_URL:-}"
if [[ -z "$url" && -n "$ctx" ]] && have_jq; then
  url=$(jq -r '.clicked_url // .clickedUrl // .link.url // empty' <<<"$ctx")
fi
[[ -n "$url" ]] || die "No clicked URL. Invoke this by Ctrl-clicking a bead link."

# https://bead.invalid/skills-0ud  ->  skills-0ud
bead_id="${url%/}"
bead_id="${bead_id##*/}"
[[ "$bead_id" =~ ^[A-Za-z][A-Za-z0-9_]*-[A-Za-z0-9]+$ ]] \
  || die "Not a bead ID: $bead_id"

# bd resolves its database from the working directory, so the pane must start
# where the click happened. Without this it inherits the plugin root and every
# lookup fails with "no beads database found".
resolve_cwd() {
  local c=""

  [[ -n "${BEADS_POPOVER_CWD:-}" ]] && { printf '%s' "$BEADS_POPOVER_CWD"; return; }

  if [[ -n "$ctx" ]] && have_jq; then
    c=$(jq -r '.pane.cwd // .pane.foreground_cwd // .focused_pane.cwd
               // .focusedPane.cwd // .worktree.path // .workspace.path // empty' \
        <<<"$ctx" 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi

  # Fall back to asking the session. Exactly one pane is focused session-wide,
  # and clicking a link focuses its pane, so that is the click's origin.
  if have_jq; then
    c=$("$HERDR" pane list 2>/dev/null \
        | jq -r '[.result.panes[]? | select(.focused)][0]
                 | (.foreground_cwd // .cwd // empty)' 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi

  printf ''
}

cwd=$(resolve_cwd)
open_pane "$cwd" "BEAD_ID=$bead_id" "BEAD_CWD=$cwd"
