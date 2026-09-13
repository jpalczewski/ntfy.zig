#!/usr/bin/env bash
set -euo pipefail

# Refreshes every git+https dependency in build.zig.zon that's pinned to a
# branch ref (`?ref=<branch>#<commit>`) to the latest commit on that branch,
# via `zig fetch --save=<name>` (which also recomputes the content hash).
# Dependencies pinned directly to a commit (no `?ref=`) are left alone —
# there's no "latest" to track for those.
#
# Run from the repository root. Requires `zig` on PATH.

zon_file="build.zig.zon"
cd "$(dirname "$0")/.."

current_name=""
found_any=0

while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*\.([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*\.\{[[:space:]]*$ ]]; then
        current_name="${BASH_REMATCH[1]}"
    elif [[ $line =~ \.url[[:space:]]*=[[:space:]]*\"(git\+[^\"]*\?ref=[^\"\#]*)\#[^\"]*\" ]]; then
        found_any=1
        url="${BASH_REMATCH[1]}"
        echo "Refreshing dependency '$current_name' ($url)"
        zig fetch --save="$current_name" "$url"
    fi
done < "$zon_file"

if [ "$found_any" -eq 0 ]; then
    echo "No branch-pinned git dependencies found in $zon_file"
fi
