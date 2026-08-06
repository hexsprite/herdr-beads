#!/usr/bin/env bash
# Detail pane body: render one bead plus its dependency tree, with every bead ID
# wrapped as an OSC 8 hyperlink so the pane is recursive — Ctrl-click a blocker
# to jump straight to it.
#
# The pane is long-lived. It watches a state file and re-renders in place when a
# new bead is selected, so clicking a link inside this pane replaces its own
# contents instead of spawning another pane.
set -uo pipefail

# Set by the link handler so each workspace's pane watches its own state.
STATE_DIR="${BEADS_STATE_DIR:-${TMPDIR:-/tmp}/beads-popover/default}"
CURRENT="$STATE_DIR/current"
HISTORY="$STATE_DIR/history"
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

# Ask the tty directly. tput honours an inherited LINES/COLUMNS, which in a
# plugin pane are the parent shell's dimensions, not this pane's — that made the
# viewport think it had 43 rows inside a 15-row pane and scrolled the title away.
term_rows() { local s; s=$(stty size 2>/dev/null) && printf '%s' "${s%% *}" || printf 24; }
term_cols() { local s; s=$(stty size 2>/dev/null) && printf '%s' "${s##* }" || printf 80; }
hr() { printf '\033[2m%*s\033[0m\n' "$(term_cols)" '' | tr ' ' '─'; }

# Re-wrap to the pane width. bd wraps its own output at a fixed 78 columns and
# ignores COLUMNS, so anything narrower than that overflows. Escape sequences
# have no width, so a naive fold counts them as visible characters, wraps far
# too early, and can slice a sequence in half.
#
# Breaks on spaces only, so bead IDs stay intact and clickable, and continuation
# lines keep the original indent to preserve the dependency tree's shape.
wrapansi() {
  perl -CSD -e '
    my $w = shift(@ARGV) || 80;
    $w = 20 if $w < 20;
    while (my $line = <STDIN>) {
      chomp $line;
      my ($indent) = $line =~ /^(\s*)/;
      $indent = "" if length($indent) > $w - 10;
      my ($out, $col, $first) = ("", 0, 1);
      for my $tok (split /(\s+)/, $line) {
        next if $tok eq "";
        my $vis = $tok;
        $vis =~ s/\e\]8;;[^\e]*\e\\//g;
        $vis =~ s/\e\[[0-9;]*[A-Za-z]//g;
        my $len = length($vis);
        if ($tok =~ /^\s+$/) {
          if ($col + $len <= $w) { $out .= $tok; $col += $len }
          next;
        }
        if ($col + $len > $w && !$first) {
          $out =~ s/[ \t]+$//;
          $out .= "\n" . $indent;
          $col = length($indent);
        }
        $out .= $tok; $col += $len; $first = 0;
      }
      print $out, "\n";
    }
  ' "$1"
}

# State file layout: line 1 is the bead ID, line 2 its repo, anything after is
# an error message. Keeping the error out of band avoids quoting a multi-line
# message through the same line-oriented format.
# The previous bead, rendered as a link at the top of the content. Clicking it
# is just another bead click, so back navigation costs nothing beyond a line of
# output — no less keybindings, no exit-status signalling.
back_line() {
  local prev
  prev=$(sed -n '1p' "$HISTORY" 2>/dev/null)
  [[ -n "$prev" ]] || return
  printf '\033[2m← back to\033[0m %s\n\n' "${prev%%$'\t'*}"
}

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

  { back_line; printf '%s\n' "$out"; } | linkify
  if tree=$( cd "${cwd:-$PWD}" && bd dep tree "$id" 2>/dev/null ) \
     && [[ -n "${tree//[[:space:]]/}" ]]; then
    hr
    printf '%s\n' "$tree" | linkify
  fi
}

# Render into a viewport of our own rather than piping through less.
#
# less mangles OSC 8: it re-emits each hyperlink as a doubled sequence with SGR
# spliced between the open and the text, and Herdr does not bind that back to a
# URL — so every bead ID in the pane goes dead and click-through stops working,
# which is the entire point of the plugin.
#
# The cost is the mouse wheel. Wheel scrolling is Herdr scrolling its own
# scrollback, which only holds content that has scrolled past; an app that draws
# its own window puts nothing there. Herdr's socket API exposes PaneScrollInfo
# and a pane.scroll_changed event but no setter, so the pane cannot be told
# where to sit. Keys it is.

# Rendered lines for the current bead, and where the viewport starts in them.
lines=()
offset=0

load() {
  local id cwd err
  id=$(sed -n '1p' "$CURRENT" 2>/dev/null)
  cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
  err=$(sed -n '3,$p' "$CURRENT" 2>/dev/null)

  lines=()
  local w; w=$(term_cols)
  while IFS= read -r l; do lines+=("$l"); done \
    < <(render "$id" "$cwd" "$err" | wrapansi "$w")
  offset=0
}

# Print a window of the rendered lines rather than dumping everything. A long
# bead would otherwise scroll its own title off the top of the pane, which is
# the one line you always want to see.
draw() {
  local rows body i last_line
  rows=$(term_rows)
  body=$(( rows - 1 ))
  (( body < 1 )) && body=1

  local max=$(( ${#lines[@]} - body ))
  (( max < 0 )) && max=0
  (( offset > max )) && offset=$max
  (( offset < 0 )) && offset=0

  printf '\033[H\033[2J'
  last_line=$(( offset + body ))
  for (( i = offset; i < last_line && i < ${#lines[@]}; i++ )); do
    printf '%s\n' "${lines[i]}"
  done

  printf '\033[%d;1H\033[2m' "$rows"
  if (( ${#lines[@]} > body )); then
    printf -- '— j/k scroll · %d-%d of %d · any other key closes —' \
      $(( offset + 1 )) "$(( last_line < ${#lines[@]} ? last_line : ${#lines[@]} ))" "${#lines[@]}"
  else
    printf -- '— any key to close · Ctrl-click an ID to follow it —'
  fi
  printf '\033[0m'
}

# Seed from the environment on first launch so the pane has content before the
# state file is consulted.
if [[ ! -s "$CURRENT" && -n "${BEAD_ID:-}" ]]; then
  printf '%s\n%s\n' "$BEAD_ID" "${BEAD_CWD:-$PWD}" >"$CURRENT"
fi

# Turn off autowrap so one rendered line always occupies exactly one row.
# Otherwise a line wider than the pane costs two rows, the viewport arithmetic
# under-counts, and the bead's title scrolls off the top — the one line that
# always has to stay visible.
printf '\033[?7l'
trap 'printf "\033[?7h"' EXIT

last=""
while :; do
  now=$(cat "$CURRENT" 2>/dev/null)
  if [[ "$now" != "$last" ]]; then
    last="$now"
    load
    draw
  fi

  if read -rsn1 -t 0.2 key; then
    case "$key" in
      j) (( offset++ )); draw ;;
      k) (( offset-- )); draw ;;
      ' ') (( offset += 10 )); draw ;;
      b) (( offset -= 10 )); draw ;;
      g) offset=0; draw ;;
      $'\e')
        # Arrow keys arrive as ESC [ A/B. Bare Escape closes.
        read -rsn2 -t 0.05 seq || exit 0
        case "$seq" in
          '[A') (( offset-- )); draw ;;
          '[B') (( offset++ )); draw ;;
          *) exit 0 ;;
        esac
        ;;
      *) exit 0 ;;
    esac
  fi
done
