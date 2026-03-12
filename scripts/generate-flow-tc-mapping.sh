#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TMP_FILE="$(mktemp)"
TMP_FILE_2="$(mktemp)"
trap 'rm -f "$TMP_FILE" "$TMP_FILE_2"' EXIT

rg -n --no-heading -o 'TC-[A-Z]+[0-9]{2}' Tests/ScriptoriaCoreTests \
  | awk -F: '{print $3 "\t" $1 ":" $2}' \
  | sort -u > "$TMP_FILE"

{
  echo "# Flow TC Mapping"
  echo
  echo "Auto-generated from \`Tests/ScriptoriaCoreTests/**/*.swift\`."
  echo
  echo "Do not edit manually. Re-generate with \`scripts/generate-flow-tc-mapping.sh\`."
  echo
} > docs/flow-tc-mapping.md

{
  echo "## By TC Group"
  echo

  cut -f1 "$TMP_FILE" \
    | sed -E 's/^TC-([A-Z]+)[0-9]{2}$/\1/' \
    | sort -u \
    | while read -r group; do
        [ -z "$group" ] && continue
        echo "### \`$group\`"
        echo
        echo "| TC ID | Test Locations |"
        echo "|---|---|"

        cut -f1 "$TMP_FILE" \
          | grep "^TC-${group}[0-9][0-9]\$" \
          | sort -u \
          | while read -r id; do
              refs="$(
                awk -F'\t' -v id="$id" '$1 == id {print $2}' "$TMP_FILE" \
                  | sort -u \
                  | awk 'BEGIN { out = "" } { if (NR > 1) out = out "<br/>"; out = out "`" $0 "`" } END { print out }'
              )"
              echo "| \`$id\` | $refs |"
            done
        echo
      done

  echo "## By Test File"
  echo
  echo "| Test File | TC IDs |"
  echo "|---|---|"

  awk -F'\t' '{ split($2, p, ":"); print p[1] "\t" $1 }' "$TMP_FILE" | sort -u > "$TMP_FILE_2"

  cut -f1 "$TMP_FILE_2" \
    | sort -u \
    | while read -r file; do
        [ -z "$file" ] && continue
        ids="$(
          awk -F'\t' -v file="$file" '$1 == file {print $2}' "$TMP_FILE_2" \
            | sort -u \
            | awk 'BEGIN { out = "" } { if (NR > 1) out = out ", "; out = out "`" $0 "`" } END { print out }'
        )"
        echo "| \`$file\` | $ids |"
      done
} >> docs/flow-tc-mapping.md
