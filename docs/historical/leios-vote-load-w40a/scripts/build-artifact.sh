#!/usr/bin/env bash
# Rebuild findings-artifact.html: a single self-contained HTML page from findings.md
# with the charts inlined as data URIs. Usage: scripts/build-artifact.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export LANG=C.UTF-8 LC_ALL=C.UTF-8
PANDOC="${PANDOC:-$(command -v pandoc || echo "$(nix build --no-link --print-out-paths nixpkgs#pandoc)/bin/pandoc")}"
STAMP=$(date -u +"%Y-%m-%d %H:%M UTC")

"$PANDOC" findings.md --from gfm+implicit_figures --to html5 --embed-resources -o /tmp/_frag.html

{ cat scripts/artifact-head.html
  printf '<p class="stamp">Rebuilt %s</p>\n' "$STAMP"
  cat scripts/artifact-board.html
  echo '<article class="doc">'
  # the masthead carries the title, so drop the document's own h1
  awk '/<h1 /{d=1} d&&/<\/h1>/{d=0;next} !d' /tmp/_frag.html
  echo '</article>'
} > findings-artifact.html

echo "findings-artifact.html: $(stat -c%s findings-artifact.html) bytes, $(grep -c 'data:image/png' findings-artifact.html) charts inlined"
