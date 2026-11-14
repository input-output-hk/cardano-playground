#!/usr/bin/env bash
# Rebuild findings.html: a standalone, self-contained page for reading locally or
# sending on. Charts are inlined as data URIs, so the file renders with no repo and
# no network.
#
# Differs from findings-artifact.html only in packaging: this one is a complete HTML
# document with a table of contents, that one is a fragment the Artifact publisher
# wraps. Both carry the same prose, the same charts and the same verdict board.
#
# The board is scripts/artifact-board.html, shared with the artifact build so the two
# cannot drift apart. It is spliced in after the document's h1 rather than passed to
# --include-before-body, which would place it above the title.
set -euo pipefail
cd "$(dirname "$0")/.."
export LANG=C.UTF-8 LC_ALL=C.UTF-8
PANDOC="${PANDOC:-$(command -v pandoc || echo "$(nix build --no-link --print-out-paths nixpkgs#pandoc)/bin/pandoc")}"
OUT="${OUT:-findings.html}"

"$PANDOC" findings.md -o /tmp/_findings_raw.html \
  --standalone --embed-resources --from gfm+implicit_figures --to html5 \
  --css scripts/findings.css \
  --metadata pagetitle="Leios vote load test — findings" \
  --toc --toc-depth=2

# Splice the board in after the first </h1>. awk rather than sed because the board is
# multi-line; the flag makes it fire once even though h1 ids repeat in the TOC.
awk -v board="scripts/artifact-board.html" '
  { print }
  !done && /<\/h1>/ {
    print ""
    while ((getline line < board) > 0) print line
    close(board)
    done = 1
  }
' /tmp/_findings_raw.html > "$OUT"
rm -f /tmp/_findings_raw.html

cards=$(grep -c 'class="card' "$OUT" || true)
[ "$cards" -eq 6 ] || { echo "error: expected 6 verdict cards, found $cards" >&2; exit 1; }
echo "$OUT: $(stat -c%s "$OUT") bytes, $(grep -c 'data:image/png' "$OUT") charts inlined, $cards verdict cards"
