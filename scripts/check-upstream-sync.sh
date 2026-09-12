#!/usr/bin/env bash
# Compare olcrtc upstream config schema with the panel's supported schema.
# Exits 0 when in sync, 1 when the panel is missing/extra fields, 2 on infrastructure errors.
set -euo pipefail

UPSTREAM_DIR="${1:-/tmp/olcrtc-upstream}"
PANEL_DIR="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

UPSTREAM_CONFIG="$UPSTREAM_DIR/internal/config/config.go"
PANEL_MAIN="$PANEL_DIR/cmd/olcrtc-manager/main.go"

[ -f "$UPSTREAM_CONFIG" ] || { echo "upstream config not found: $UPSTREAM_CONFIG" >&2; exit 2; }
[ -f "$PANEL_MAIN" ] || { echo "panel main.go not found: $PANEL_MAIN" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- extract yaml fields from upstream Settings struct (the shared schema) ---
# Parses: <Type> <Name> `yaml:"tag"`
awk '
BEGIN{in_struct=0}
/Settings struct/{in_struct=1}
in_struct && /^}/{in_struct=0}
in_struct && /`yaml:"/{
    line=$0
    match(line, /yaml:"[^"]+"/)
    tag=substr(line, RSTART, RLENGTH)
    gsub(/yaml:"/, "", tag)
    gsub(/"/, "", tag)
    field=tag
    gsub(/,.*/, "", field)
    print field
}
' "$UPSTREAM_CONFIG" > "$tmp/upstream.schema"

# --- extract yaml/json fields the panel emits for a location ---
# The panel mirrors the shared schema inside olcrtcRuntimeConfig. Grab every yaml/json tag
# from the runtime/config block of the panel.
awk '
/`yaml:"/ || /`json:"/{
    line=$0
    while (match(line, /(yaml|json):"[^"]+"/)) {
        t=substr(line, RSTART, RLENGTH)
        gsub(/^(yaml|json):"/, "", t)
        gsub(/"$/, "", t)
        f=t
        gsub(/,.*/, "", f)
        print f
        line=substr(line, RSTART+RLENGTH)
    }
}
' "$PANEL_MAIN" | sort -u > "$tmp/panel.schema"

sort -u "$tmp/upstream.schema" > "$tmp/upstream.sorted"

missing=0
extra=0
: > "$tmp/missing.txt"
: > "$tmp/extra.txt"

while read -r f; do
    grep -qx "$f" "$tmp/panel.schema" || { echo "$f" >> "$tmp/missing.txt"; missing=$((missing+1)); }
done < "$tmp/upstream.sorted"

while read -r f; do
    grep -qx "$f" "$tmp/upstream.sorted" || { echo "$f" >> "$tmp/extra.txt"; extra=$((extra+1)); }
done < "$tmp/panel.schema"

echo "=== Upstream schema fields: $(wc -l < "$tmp/upstream.sorted") ==="
echo "=== Panel schema fields:    $(wc -l < "$tmp/panel.schema") ==="

if [ "$missing" -gt 0 ]; then
    echo ""
    echo "!!! Panel is MISSING fields the upstream olcrtc now supports:"
    cat "$tmp/missing.txt"
fi

if [ "$extra" -gt 0 ]; then
    echo ""
    echo "=== Panel emits fields the upstream schema does not list (may be OK for panel-specific use):"
    cat "$tmp/extra.txt"
fi

echo ""
if [ "$missing" -gt 0 ]; then
    exit 1
fi
echo "OK: panel covers all upstream schema fields."
exit 0