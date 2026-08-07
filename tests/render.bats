#!/usr/bin/env bats
# Covers the two perl programs in scripts/lib/render.sh. Both manipulate escape
# sequences, both have regressed silently before, and a regression is invisible
# in the pane — a bead ID just quietly stops responding to Ctrl-click, or a line
# wraps at the wrong column.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export BEADS_POPOVER_INDEX="$BATS_TEST_TMPDIR/index.tsv"
  printf 'fo\t/repo/focuster\nws\t/repo/wonderschool\nralph\t/repo/ralph\n' \
    >"$BEADS_POPOVER_INDEX"
  # Sourcing must be side-effect free, and detail.sh runs under these options.
  set -uo pipefail
  source "$ROOT/scripts/lib/render.sh"
  ESC=$'\033'
  OSC_END=$'\033\\'
}

# ESC is invisible and bats compares bytes, so failures are unreadable without
# this. Every assertion below is written against visualised output.
vis() { perl -pe 's/\e/<ESC>/g'; }

lk()  { printf '%s\n' "$1" | linkify | vis; }
wr()  { printf '%s\n' "$2" | wrapansi "$1"; }
wrv() { printf '%s\n' "$2" | wrapansi "$1" | vis; }

# What linkify should emit for a bare ID.
link() {
  printf '<ESC>]8;;https://bead.invalid/%s<ESC>\\<ESC>[4m%s<ESC>[24m<ESC>]8;;<ESC>\\' \
    "$1" "$1"
}

# --- linkify ---------------------------------------------------------------

@test "linkify: wraps a bare bead ID" {
  run lk "see fo-g1kd6 today"
  [ "$status" -eq 0 ]
  [ "$output" = "see $(link fo-g1kd6) today" ]
}

@test "linkify: matches an ID that starts immediately after an SGR" {
  # The original regression: bd colours its IDs, so the 'm' ending the SGR sits
  # directly before the ID. A word-boundary lookbehind refuses to match there.
  run lk "${ESC}[36mfo-g1kd6${ESC}[0m"
  [ "$status" -eq 0 ]
  [ "$output" = "<ESC>[36m$(link fo-g1kd6)<ESC>[0m" ]
}

@test "linkify: keeps bd's surrounding colour intact" {
  # linkify must not emit an SGR reset of its own — that would drop bd's colour
  # for the rest of the line.
  run lk "${ESC}[33mstatus fo-komud open${ESC}[0m"
  [ "$status" -eq 0 ]
  [ "$output" = "<ESC>[33mstatus $(link fo-komud) open<ESC>[0m" ]
}

@test "linkify: handles a dotted numeric suffix" {
  run lk "ralph-tui-348.4"
  [ "$status" -eq 0 ]
  [ "$output" = "$(link ralph-tui-348.4)" ]
}

@test "linkify: leaves an ID already inside a URL alone" {
  run lk "https://bead.invalid/fo-g1kd6"
  [ "$status" -eq 0 ]
  [ "$output" = "https://bead.invalid/fo-g1kd6" ]
}

@test "linkify: leaves an existing OSC 8 target untouched" {
  # The URL inside the sequence must survive byte-for-byte; rewriting it would
  # produce a nested target that Herdr cannot bind.
  run lk "${ESC}]8;;https://bead.invalid/fo-g1kd6${OSC_END}fo-g1kd6${ESC}]8;;${OSC_END}"
  [ "$status" -eq 0 ]
  [[ "$output" == "<ESC>]8;;https://bead.invalid/fo-g1kd6<ESC>\\"* ]]
  [[ "$output" == *"<ESC>]8;;<ESC>\\" ]]
}

@test "linkify: ignores ordinary hyphenated English" {
  run lk "a well-known follow-up"
  [ "$status" -eq 0 ]
  [ "$output" = "a well-known follow-up" ]
}

@test "linkify: ignores an unknown prefix" {
  run lk "nope-abc123"
  [ "$status" -eq 0 ]
  [ "$output" = "nope-abc123" ]
}

@test "linkify: passes text through when there are no prefixes at all" {
  # Empty index and no BEAD_ID. Under set -u an empty array expansion kills the
  # pane, and an empty alternation would match everywhere.
  : >"$BEADS_POPOVER_INDEX"
  run lk "fo-g1kd6"
  [ "$status" -eq 0 ]
  [ "$output" = "fo-g1kd6" ]
}

@test "linkify: an empty prefix list does not trip set -u on bash 3.2" {
  # bash before 4.4 treats "${arr[@]}" on an empty array as unbound, which under
  # detail.sh's set -u kills the pane outright. macOS still ships 3.2 as
  # /bin/bash, so anyone without a newer bash on PATH hits this on the first
  # render after a cleared TMPDIR. bats itself runs under a modern bash, so this
  # has to spawn the old one explicitly.
  [ -x /bin/bash ] || skip "no /bin/bash"
  : >"$BEADS_POPOVER_INDEX"
  run /bin/bash -c \
    "set -uo pipefail; source '$ROOT/scripts/lib/render.sh'; printf 'fo-g1kd6\n' | linkify"
  [ "$status" -eq 0 ]
  [ "$output" = "fo-g1kd6" ]
}

@test "linkify: uses BEAD_ID's prefix when the index has not seen it" {
  : >"$BEADS_POPOVER_INDEX"
  export BEAD_ID=new-xyz
  run lk "new-xyz"
  [ "$status" -eq 0 ]
  [ "$output" = "$(link new-xyz)" ]
}

# --- wrapansi --------------------------------------------------------------

@test "wrapansi: breaks on a space at the width" {
  run wr 20 "aaaa bbbb cccc dddd eeee"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "aaaa bbbb cccc dddd" ]
  [ "${lines[1]}" = "eeee" ]
}

@test "wrapansi: a line exactly at the width does not wrap" {
  run wr 20 "aaaa bbbb cccc dddd"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "aaaa bbbb cccc dddd" ]
}

@test "wrapansi: escape sequences do not count toward the width" {
  # Visible width is 19, so this stays on one line despite being far longer in
  # bytes. A naive fold would wrap it several times.
  run wrv 20 "${ESC}[31maaaa${ESC}[0m ${ESC}[32mbbbb${ESC}[0m cccc dddd"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "<ESC>[31maaaa<ESC>[0m <ESC>[32mbbbb<ESC>[0m cccc dddd" ]
}

@test "wrapansi: never splits a bead ID" {
  # A split ID is two dead half-links.
  run wr 20 "blocked by fo-g1kd6 and more"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fo-g1kd6"* ]]
  [[ "$output" != *$'fo-g1kd\n'* ]]
  [[ "$output" != *$'fo-\n'* ]]
}

@test "wrapansi: an OSC 8 link survives unbroken" {
  local id="${ESC}]8;;https://bead.invalid/fo-g1kd6${OSC_END}fo-g1kd6${ESC}]8;;${OSC_END}"
  run wrv 20 "aaaa bbbb cccc $id dddd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<ESC>]8;;https://bead.invalid/fo-g1kd6<ESC>\\fo-g1kd6<ESC>]8;;<ESC>\\"* ]]
}

@test "wrapansi: a short indented line is left alone" {
  run wr 20 "    aaa bbb ccc"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "    aaa bbb ccc" ]
}

@test "wrapansi: continuation lines keep the original indent" {
  run wr 20 "    aaa bbb ccc ddd eee fff"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 1 ]
  [ "${lines[1]:0:4}" = "    " ]
}

@test "wrapansi: drops the indent when it would leave under 10 columns" {
  run wr 20 "              aaa bbb ccc ddd"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 1 ]
  [ "${lines[1]:0:1}" != " " ]
}

@test "wrapansi: floors the width at 20" {
  run wr 5 "aaaa bbbb cccc dddd"
  [ "$status" -eq 0 ]
  # 19 visible columns: under the floor of 20, so it stays on one line.
  [ "${#lines[@]}" -eq 1 ]
}

@test "wrapansi: leaves multibyte text intact" {
  run wr 40 "← back to fo-g1kd6"
  [ "$status" -eq 0 ]
  [ "$output" = "← back to fo-g1kd6" ]
}
