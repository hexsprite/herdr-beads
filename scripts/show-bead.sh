#!/usr/bin/env bash
# Link-handler action: work out which bead was clicked and show it.
#
# Failures here are invisible by default — a click that does nothing looks
# identical to a click that missed. So every error path opens the pane anyway
# with the message inside it.
set -uo pipefail

PLUGIN_ID="beads.popover"
ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_ROOT="${TMPDIR:-/tmp}/beads-popover"
HERDR="${HERDR_BIN_PATH:-herdr}"

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Herdr does not document the context payload and it has changed shape between
# versions, so always keep the last one on disk. Gitignored, one file, no growth.
[[ -n "$ctx" ]] && printf '%s\n' "$ctx" >"$ROOT/last-context.json" 2>/dev/null

have_jq() { command -v jq >/dev/null 2>&1; }

# State is per workspace, so each workspace can keep its own visible detail pane
# with its own back trail. A single global slot would mean the second workspace
# hijacked the first one's pane.
workspace=""
if [[ -n "$ctx" ]] && have_jq; then
  workspace=$(jq -r '.workspace_id // empty' <<<"$ctx" 2>/dev/null)
fi
STATE_DIR="$STATE_ROOT/${workspace:-default}"
PANE_FILE="$STATE_DIR/pane"
CURRENT="$STATE_DIR/current"
HISTORY="$STATE_DIR/history"
mkdir -p "$STATE_DIR" 2>/dev/null

# Is the detail pane from a previous click still on screen?
#
# The recorded pane id can go missing while the pane itself is very much alive —
# a cleared TMPDIR is enough. Recovering it by label matters: without this the
# handler concludes there is no pane and opens a second one next to the first.
live_pane() {
  have_jq || return 1

  local prev=""
  [[ -r "$PANE_FILE" ]] && prev=$(<"$PANE_FILE")
  if [[ -n "$prev" ]] && "$HERDR" pane list 2>/dev/null \
      | jq -e --arg p "$prev" '[.result.panes[]? | select(.pane_id==$p)] | length > 0' \
        >/dev/null 2>&1; then
    return 0
  fi

  # Adopt an existing detail pane in this workspace, if one is still open.
  local found
  found=$("$HERDR" pane list 2>/dev/null \
    | jq -r --arg w "$workspace" \
        '[.result.panes[]? | select(.label=="Bead") | select($w=="" or .workspace_id==$w)][0]
         | (.pane_id // empty)' 2>/dev/null)
  [[ -n "$found" ]] || return 1
  printf '%s' "$found" >"$PANE_FILE" 2>/dev/null
  return 0
}

# Selecting a bead means writing it to the state file. A live detail pane polls
# that file and redraws itself, so clicking a link inside the pane replaces its
# contents instead of opening another pane — and never closes the pane the
# click came from.
select_bead() {
  local id="$1" cwd="$2" err="${3:-}"

  # State lives in TMPDIR and outlives any single pane. Without this, the first
  # click after the pane is gone offers "back" to whatever bead was last viewed
  # hours ago, possibly in an unrelated repo.
  local fresh=0
  live_pane || fresh=1
  if (( fresh )); then
    : >"$HISTORY" 2>/dev/null
    : >"$CURRENT" 2>/dev/null
  fi

  # Keep a trail so the detail pane can offer a way back. Clicking the back link
  # selects the bead already on top of the trail, so that case pops instead of
  # pushing and the history does not grow every time you retrace a step.
  if [[ -n "$id" ]] && (( ! fresh )); then
    local top prev_id prev_cwd
    top=$(sed -n '1p' "$HISTORY" 2>/dev/null)
    if [[ "${top%%$'\t'*}" == "$id" ]]; then
      sed -i '' '1d' "$HISTORY" 2>/dev/null
    else
      prev_id=$(sed -n '1p' "$CURRENT" 2>/dev/null)
      prev_cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
      if [[ -n "$prev_id" && "$prev_id" != "$id" ]]; then
        printf '%s\t%s\n%s' "$prev_id" "$prev_cwd" "$(cat "$HISTORY" 2>/dev/null)" \
          >"$HISTORY.new" 2>/dev/null
        mv "$HISTORY.new" "$HISTORY" 2>/dev/null
      fi
    fi
  fi

  { printf '%s\n%s\n' "$id" "$cwd"; [[ -n "$err" ]] && printf '%s\n' "$err"; } \
    >"$CURRENT" 2>/dev/null

  (( ! fresh )) && exit 0

  # Split, not popup. Herdr does not route Ctrl-clicks that originate inside a
  # plugin popup, so links rendered in one are dead — which kills the whole
  # point. Ordinary panes route clicks normally. (Overlay routes clicks too,
  # but zooms the entire tab, far too heavy for glancing at one issue.)
  local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint detail
              --placement split --direction down --focus)
  [[ -n "$cwd" ]] && args+=(--cwd "$cwd")
  [[ -n "$id" ]] && args+=(--env "BEAD_ID=$id" --env "BEAD_CWD=$cwd")
  # The pane reads its own state directory, so it follows the workspace it was
  # opened in rather than a global one.
  args+=(--env "BEADS_STATE_DIR=$STATE_DIR")

  # Without this the split lands in whichever workspace happens to hold UI
  # focus, which is not necessarily where the click came from. --workspace is
  # not accepted alongside it: a split always targets an existing pane, and the
  # pane already determines its workspace.
  local target
  if [[ -n "$ctx" ]] && have_jq; then
    target=$(jq -r '.focused_pane_id // empty' <<<"$ctx" 2>/dev/null)
    [[ -n "$target" ]] && args+=(--target-pane "$target")
  fi

  local out pane
  out=$("$HERDR" "${args[@]}" 2>&1)

  # A stale target pane fails the whole open and nothing appears on screen.
  # Better to land in the focused workspace than to do nothing at all.
  if [[ -n "$target" ]] && grep -q 'pane_not_found' <<<"$out"; then
    local retry=()
    for a in "${args[@]}"; do
      [[ "$a" == "--target-pane" || "$a" == "$target" ]] && continue
      retry+=("$a")
    done
    out=$("$HERDR" "${retry[@]}" 2>&1)
  fi

  if have_jq; then
    pane=$(printf '%s' "$out" \
      | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
    [[ -n "$pane" ]] && printf '%s' "$pane" >"$PANE_FILE" 2>/dev/null
  fi
  exit 0
}

die() { select_bead "" "" "$1"; }

# Herdr sets this directly for link handlers (the mechanism official.browser
# uses). The context JSON is a fallback for other invocation paths.
url="${HERDR_PLUGIN_CLICKED_URL:-}"
if [[ -z "$url" && -n "$ctx" ]] && have_jq; then
  url=$(jq -r '.clicked_url // .clickedUrl // .link.url // empty' <<<"$ctx")
fi
[[ -n "$url" ]] || die "No clicked URL. Invoke this by Ctrl-clicking a bead link."

# bead://skills-0ud  ->  skills-0ud
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

select_bead "$bead_id" "$cwd"
