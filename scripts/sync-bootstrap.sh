#!/usr/bin/env bash
# Sync the canonical bootstrap halves (section 1.2 of the family plan) from the
# js_widget_runtime pin into Sources/JSRCore/Resources/ and write the provenance line.
# Run scripts/fetch-conformance.sh first. Overwrites only when the content differs.
# JSR_CONFORMANCE_DIR overrides the pin directory.
set -euo pipefail

dir="${JSR_CONFORMANCE_DIR:-.conformance}"
src="$dir/js_widget_runtime/src"
dest="$(dirname "$0")/../Sources/JSRCore/Resources"

sha="$(git -C "$src" rev-parse --short=12 HEAD)"
mkdir -p "$dest"
for f in bootstrap-runtime.js bootstrap-widget.js; do
  tmp="$(mktemp)"
  printf '// Generated from IstiN/js_widget_runtime@%s:src/%s by scripts/sync-bootstrap.sh — do not edit\n' "$sha" "$f" > "$tmp"
  cat "$src/$f" >> "$tmp"
  if ! cmp -s "$tmp" "$dest/$f"; then
    cp "$tmp" "$dest/$f"
    echo "sync-bootstrap: wrote $dest/$f"
  fi
  rm -f "$tmp"
done
