#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MAP_FILE="docs/flow-gui-tc-mapping.md"

if [ ! -f "$MAP_FILE" ]; then
  echo "Missing mapping file: $MAP_FILE"
  exit 1
fi

required_headers=(
  "TC Group"
  "Representative TC IDs"
  "GUI Surface"
  "Event Fields"
  "Validation Method"
)

for header in "${required_headers[@]}"; do
  if ! rg -q "$header" "$MAP_FILE"; then
    echo "Missing required header in $MAP_FILE: $header"
    exit 1
  fi
done

groups=(Y C E CLI GP P PR R)
mins=(3 3 5 5 2 2 2 2)

for i in "${!groups[@]}"; do
  group="${groups[$i]}"
  min="${mins[$i]}"
  count="$(
    (rg -o "TC-${group}[0-9]{2}" "$MAP_FILE" || true) \
      | sort -u \
      | wc -l \
      | tr -d ' '
  )"
  if [ "$count" -lt "$min" ]; then
    echo "Group ${group} has ${count} mapped TC IDs, expected >= ${min}"
    exit 1
  fi
done

required_error_codes=(
  "flow.path.invalid_path_kind"
  "flow.path.not_found"
  "flow.agent.rounds_exceeded"
  "flow.wait.cycles_exceeded"
  "flow.steps.exceeded"
  "flow.step.timeout"
  "flow.gate.process_exit_nonzero"
  "flow.script.process_exit_nonzero"
  "flow.agent.failed"
  "flow.agent.interrupted"
  "flow.business_failed"
  "flow.dryrun.fixture_unknown_state"
  "flow.dryrun.fixture_unconsumed_items"
  "flow.dryrun.fixture_unused_state_data"
)

for code in "${required_error_codes[@]}"; do
  if ! rg -q "$code" "$MAP_FILE"; then
    echo "Missing required error code mapping in $MAP_FILE: $code"
    exit 1
  fi
done

echo "Flow GUI TC mapping checks passed."
