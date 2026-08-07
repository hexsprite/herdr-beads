#!/usr/bin/env bash
# Text transforms for the detail pane, split out of detail.sh so they can be
# exercised directly. Sourcing this file must not do anything observable — the
# tests source it, and detail.sh sources it before it owns a terminal.
#
# Both functions are perl programs with real edge cases (escape sequences that
# must not be counted, split, or reordered), and both have regressed silently
# in the past. tests/render.bats covers them.

# Prefix index built by show-bead.sh: "<prefix>\t<repo>" per line.
INDEX="${BEADS_POPOVER_INDEX:-${TMPDIR:-/tmp}/beads-popover-index.tsv}"

prefixes() {
  local p=()
  [[ -r "$INDEX" ]] && while IFS=$'\t' read -r pre _; do
    [[ -n "$pre" ]] && p+=("$pre")
  done <"$INDEX"
  # The bead on screen may come from a repo the index has not seen yet.
  [[ -n "${BEAD_ID:-}" ]] && p+=("${BEAD_ID%%-*}")
  printf '%s\n' "${p[@]}" | sort -u | grep -v '^$' | paste -sd'|' -
}

# Wrap bare bead IDs in OSC 8 links pointing back at our own handler.
#
# Matching is driven by the prefixes of the beads repos actually on this machine
# rather than by the shape of the suffix. Shape heuristics do not work: real IDs
# are anything from fo-g1kd6 to fo-komud to ralph-tui-348.4, and any rule loose
# enough to catch all of them also catches ordinary hyphenated English.
#
# The lookbehind skips IDs already inside a URL so existing links survive intact.
#
# Targets must be http(s). Herdr only turns http/https OSC 8 targets into click
# targets and consults link_handlers afterwards, so a bead:// link renders as
# inert underlined text that nothing can follow. bead.invalid is reserved by
# RFC 2606, so a click that misses the plugin cannot reach a real site.
#
# Underline only, no colour of our own: bd colours its output and an SGR reset
# here would drop that colour for the rest of the line. Underline marks the link
# without touching what bd already set.
linkify() {
  local alt; alt=$(prefixes)
  [[ -n "$alt" ]] || { cat; return; }
  BEADS_PREFIX_ALT="$alt" perl -pe '
    BEGIN { $alt = $ENV{BEADS_PREFIX_ALT} }
    # Stash escape sequences first. bd colours its IDs, which puts the "m" that
    # ends an SGR immediately before the ID — a word character, so the
    # word-boundary lookbehind would refuse to match and nothing would linkify.
    my @esc;
    s/(\e\[[0-9;]*[A-Za-z]|\e\]8;;[^\e]*\e\\)/push @esc, $1; "\x00" . $#esc . "\x01"/ge;
    s{(?<![\w/.-])((?:$alt)(?:-[a-zA-Z0-9_.]+)+)(?![\w-])}
     {\e]8;;https://bead.invalid/$1\e\\\e[4m$1\e[24m\e]8;;\e\\}gi;
    s/\x00(\d+)\x01/$esc[$1]/g;
  '
}

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
