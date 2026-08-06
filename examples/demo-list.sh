#!/usr/bin/env bash
# Print `bd list` with every bead ID wrapped as an OSC 8 hyperlink, so the IDs
# are Ctrl-clickable in Herdr. Handy for demos and for seeing what the plugin
# feels like before deciding whether to patch bd itself.
#
# Usage: examples/demo-list.sh [bd list args...]
set -uo pipefail

bd list "$@" 2>&1 | perl -pe '
  s{(?<![\w/.-])([a-z][a-z0-9_]*-(?=[a-z0-9]{2,8}(?![\w-]))[a-z]*[0-9][a-z0-9]*)(?![\w-])}
   {\e]8;;https://bead.invalid/$1\e\\$1\e]8;;\e\\}gi
'
