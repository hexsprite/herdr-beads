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
# Matching is driven by the prefixes of the beads repos actually on this machine
# rather than by the shape of the suffix. Shape heuristics do not work: real IDs
# are anything from fo-g1kd6 to fo-komud to ralph-tui-348.4, and any rule loose
# enough to catch all of them also catches ordinary hyphenated English.
#
# The lookbehind skips IDs already inside a URL so existing links survive intact.
INDEX="${TMPDIR:-/tmp}/beads-popover-index.tsv"

prefixes() {
  local p=()
  [[ -r "$INDEX" ]] && while IFS=$'\t' read -r pre _; do
    [[ -n "$pre" ]] && p+=("$pre")
  done <"$INDEX"
  # The bead on screen may come from a repo the index has not seen yet.
  [[ -n "${BEAD_ID:-}" ]] && p+=("${BEAD_ID%%-*}")
  printf '%s\n' "${p[@]}" | sort -u | grep -v '^$' | paste -sd'|' -
}

linkify() {
  local alt; alt=$(prefixes)
  [[ -n "$alt" ]] || { cat; return; }
  BEADS_PREFIX_ALT="$alt" perl -pe '
    BEGIN { $alt = $ENV{BEADS_PREFIX_ALT} }
    s{(?<![\w/.-])((?:$alt)(?:-[a-zA-Z0-9_.]+)+)(?![\w-])}
     {\e]8;;https://bead.invalid/$1\e\\\e[4;38;5;75m$1\e[24;39m\e]8;;\e\\}gi;
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
# Emitted already linked, rather than handed to linkify, so the whole phrase is
# one click target instead of just the ID inside it.
back_line() {
  local prev id
  prev=$(sed -n '1p' "$HISTORY" 2>/dev/null)
  [[ -n "$prev" ]] || return
  id="${prev%%$'\t'*}"
  printf '\033]8;;https://bead.invalid/%s\033\\\033[4;38;5;75m← back to %s\033[24;39m\033]8;;\033\\\n\n' \
    "$id" "$id"
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

  back_line
  printf '%s\n' "$out" | linkify
  if tree=$( cd "${cwd:-$PWD}" && bd dep tree "$id" 2>/dev/null ) \
     && [[ -n "${tree//[[:space:]]/}" ]]; then
    hr
    printf '%s\n' "$tree" | linkify
  fi
}

# Page with less: it handles scrolling, search and resize, and on the alternate
# screen Herdr translates the mouse wheel into scrolling for it.
#
# -L is load-bearing. A LESSOPEN preprocessor (commonly "| bat ... %s") rewrites
# every OSC 8 hyperlink into a doubled sequence with SGR spliced between the
# open and the text, which Herdr will not bind back to a URL — so every bead ID
# in the pane silently stops responding to Ctrl-click. -L ignores LESSOPEN and
# the links survive intact. LESSOPEN is also cleared for anything that reads it
# directly.
TMP="$STATE_DIR/render.$$"
trap 'rm -f "$TMP"' EXIT

# Seed from the environment on first launch so the pane has content before the
# state file is consulted.
if [[ ! -s "$CURRENT" && -n "${BEAD_ID:-}" ]]; then
  printf '%s\n%s\n' "$BEAD_ID" "${BEAD_CWD:-$PWD}" >"$CURRENT"
fi

while :; do
  snapshot=$(cat "$CURRENT" 2>/dev/null)
  id=$(sed -n '1p' "$CURRENT" 2>/dev/null)
  cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
  err=$(sed -n '3,$p' "$CURRENT" 2>/dev/null)

  render "$id" "$cwd" "$err" | wrapansi "$(term_cols)" >"$TMP"

  # Replace less's default filename prompt, which would show a temp path, with
  # the bead being viewed and the keys that matter. %lt-%lb of %L is the visible
  # line range; less fills it in as you scroll.
  prompt="${id:-beads} · ctrl-click an ID to follow · j/k scroll · / search · q close"

  # Watch for a new selection while the pager is up, and retire the pager when
  # one arrives so the same pane redraws with the new bead.
  ( while :; do
      sleep 0.2
      [[ "$(cat "$CURRENT" 2>/dev/null)" != "$snapshot" ]] || continue
      pkill -P $$ -x less 2>/dev/null
      break
    done ) &
  watcher=$!

  LESSOPEN= less -R -L -Ps"$prompt" "$TMP"

  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null

  # less exited on its own (the user quit) rather than being replaced.
  [[ "$(cat "$CURRENT" 2>/dev/null)" == "$snapshot" ]] && exit 0
done
