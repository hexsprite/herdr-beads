#!/usr/bin/env bash
# Link-handler action: work out which bead was clicked and open the detail pane
# for it.
#
# Failures here are invisible by default — a click that does nothing looks
# identical to a click that missed. So every error path opens the popup anyway
# with the message inside it.
set -uo pipefail

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Kept for diagnosing context-shape changes across Herdr versions; harmless.
if [[ -n "${BEADS_POPOVER_DEBUG:-}" && -n "$ctx" ]]; then
  printf '%s\n' "$ctx" >"${HERDR_PLUGIN_ROOT:-.}/last-context.json"
fi

open_pane() {
  # $1 = cwd (may be empty), rest = --env args
  local cwd="$1"; shift
  local args=(plugin pane open --plugin beads.popover --entrypoint detail --focus)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  while (($#)); do args+=(--env "$1"); shift; done
  exec "${HERDR_BIN_PATH:-herdr}" "${args[@]}"
}

die() {
  open_pane "" "BEAD_ERROR=$1"
}

# Herdr sets this directly for link handlers (same mechanism official.browser
# uses). The context JSON is a fallback for other invocation paths.
url="${HERDR_PLUGIN_CLICKED_URL:-}"
if [[ -z "$url" && -n "$ctx" ]] && command -v jq >/dev/null 2>&1; then
  url=$(jq -r '.clicked_url // .clickedUrl // .link.url // empty' <<<"$ctx")
fi
[[ -n "$url" ]] || die "No clicked URL. Invoke this by Ctrl-clicking a bead link."

# https://bead.invalid/skills-0ud  ->  skills-0ud
bead_id="${url%/}"
bead_id="${bead_id##*/}"
[[ "$bead_id" =~ ^[A-Za-z][A-Za-z0-9_]*-[A-Za-z0-9]+$ ]] \
  || die "Not a bead ID: $bead_id"

# bd resolves its database from the working directory, so the pane must start
# where the click happened — not where Herdr happens to be.
cwd=""
if [[ -n "$ctx" ]] && command -v jq >/dev/null 2>&1; then
  cwd=$(jq -r '.pane.cwd // .focused_pane.cwd // .focusedPane.cwd
               // .worktree.path // .workspace.path // empty' <<<"$ctx")
fi

open_pane "$cwd" "BEAD_ID=$bead_id" "BEAD_CWD=$cwd"
