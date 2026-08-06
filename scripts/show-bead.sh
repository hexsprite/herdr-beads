#!/usr/bin/env bash
# Link-handler action: work out which bead was clicked and show it.
#
# Failures here are invisible by default — a click that does nothing looks
# identical to a click that missed. So every error path opens the pane anyway
# with the message inside it.
set -uo pipefail

PLUGIN_ID="beads.popover"
ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${TMPDIR:-/tmp}/beads-popover"
GEN_FILE="$STATE_DIR/generation"
HERDR="${HERDR_BIN_PATH:-herdr}"
mkdir -p "$STATE_DIR" 2>/dev/null

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Herdr does not document the context payload and it has changed shape between
# versions, so always keep the last one on disk. Gitignored, one file, no growth.
[[ -n "$ctx" ]] && printf '%s\n' "$ctx" >"$ROOT/last-context.json" 2>/dev/null

have_jq() { command -v jq >/dev/null 2>&1; }

# Popups are session singletons and cannot be closed from here: they have no
# pane ID, and `plugin pane close` requires one. A second open just fails with
# "popup already open".
#
# So instead of closing the old popup, ask it to leave. Bumping the generation
# counter makes any running popup exit on its next poll, freeing the slot. The
# retry loop covers the gap between asking and it actually exiting.
#
# The alternative was overlay placement, which allows repeated opens — but
# Herdr overlays are zoomed to the full tab, which is far too heavy for
# glancing at one issue.
open_pane() {
  local cwd="$1"; shift
  local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint detail --focus)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  while (($#)); do args+=(--env "$1"); shift; done

  local gen
  gen=$(( $(cat "$GEN_FILE" 2>/dev/null || echo 0) + 1 ))
  printf '%s' "$gen" >"$GEN_FILE" 2>/dev/null

  local i out
  for i in 1 2 3 4 5 6 7 8 9 10; do
    out=$("$HERDR" "${args[@]}" 2>&1)
    grep -q '"type":"ok"' <<<"$out" && exit 0
    grep -q 'popup already open' <<<"$out" || break
    sleep 0.15
  done
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
[[ "$bead_id" =~ ^[A-Za-z][A-Za-z0-9_]*(-[A-Za-z0-9_]+)*-[A-Za-z0-9_.]+$ ]] \
  || die "Not a bead ID: $bead_id"

# The pane the click came from. Often the right repo, but not when an agent
# mentions a bead from a pane that is parked somewhere else.
pane_cwd() {
  local c=""
  # Herdr 0.8 sends a flat payload: focused_pane_cwd, workspace_cwd, clicked_url,
  # link_handler_id. The nested forms are kept in case older builds differ.
  if [[ -n "$ctx" ]] && have_jq; then
    c=$(jq -r '.focused_pane_cwd // .workspace_cwd
               // .pane.cwd // .focused_pane.cwd // empty' <<<"$ctx" 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi
  # Exactly one pane is focused session-wide, and clicking a link focuses its
  # pane, so that is the click's origin.
  if have_jq; then
    c=$("$HERDR" pane list 2>/dev/null \
        | jq -r '[.result.panes[]? | select(.focused)][0]
                 | (.foreground_cwd // .cwd // empty)' 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi
  printf ''
}

# Map bead prefixes to repositories, so an ID resolves no matter which pane it
# was clicked from. Reading the first line of issues.jsonl is far cheaper than
# starting bd in every candidate repo.
ROOTS="${BEADS_POPOVER_ROOTS:-$HOME/co:$HOME/src:$HOME/code:$HOME/projects}"
INDEX="${TMPDIR:-/tmp}/beads-popover-index.tsv"

build_index() {
  local root repo id
  : >"$INDEX"
  IFS=':' read -ra roots <<<"$ROOTS"
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    for f in "$root"/*/.beads/issues.jsonl; do
      [[ -r "$f" ]] || continue
      repo=$(dirname "$(dirname "$f")")
      id=$(head -1 "$f" 2>/dev/null | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
      [[ -n "$id" ]] && printf '%s\t%s\n' "${id%%-*}" "$repo" >>"$INDEX"
    done
  done
}

# Candidate repos for this ID: the clicking pane first (cheapest and usually
# right), then every repo whose prefix matches.
candidates() {
  local prefix="${bead_id%%-*}" pc
  pc=$(pane_cwd)
  [[ -n "$pc" ]] && printf '%s\n' "$pc"

  [[ -r "$INDEX" ]] || build_index
  local hits
  hits=$(awk -F'\t' -v p="$prefix" '$1==p {print $2}' "$INDEX" 2>/dev/null)
  # A prefix added since the index was built looks like a miss; rebuild once.
  if [[ -z "$hits" ]]; then
    build_index
    hits=$(awk -F'\t' -v p="$prefix" '$1==p {print $2}' "$INDEX" 2>/dev/null)
  fi
  printf '%s\n' "$hits"
}

resolve_cwd() {
  [[ -n "${BEADS_POPOVER_CWD:-}" ]] && { printf '%s' "$BEADS_POPOVER_CWD"; return; }
  local c
  while read -r c; do
    [[ -n "$c" && -d "$c" ]] || continue
    if (cd "$c" && bd show "$bead_id" >/dev/null 2>&1); then
      printf '%s' "$c"; return
    fi
  done < <(candidates)
  printf ''
}

cwd=$(resolve_cwd)
if [[ -z "$cwd" ]]; then
  die "No repo contains $bead_id.

Searched every .beads repo under:
  ${ROOTS//:/
  }

Set BEADS_POPOVER_ROOTS if your repos live elsewhere."
fi

open_pane "$cwd" "BEAD_ID=$bead_id" "BEAD_CWD=$cwd"
