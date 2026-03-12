#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[flow-db] Running baseline migration regression test..."
swift test --filter ScriptoriaCoreTests.ScriptoriaCoreBehaviorTests/testLegacyMigration

FLOW_SCHEMA_FILES=(
  "Sources/ScriptoriaCore/Storage/DatabaseManager.swift"
  "Sources/ScriptoriaCore/Storage/DatabaseManager+Flow.swift"
)

flow_table_markers=(
  "flow_definitions"
  "flow_runs"
  "flow_steps"
  "flow_warnings"
  "flow_command_events"
  "flow_compile_artifacts"
)

flow_schema_detected=0
for marker in "${flow_table_markers[@]}"; do
  for file in "${FLOW_SCHEMA_FILES[@]}"; do
    if [ -f "$file" ] && rg -q "$marker" "$file"; then
      flow_schema_detected=1
      break 2
    fi
  done
done

if [ "$flow_schema_detected" -eq 0 ]; then
  echo "[flow-db] Flow schema markers are not present in ${FLOW_SCHEMA_FILES[*]} yet; skip flow-specific migration assertions."
  exit 0
fi

echo "[flow-db] Flow schema markers detected, checking migration tests..."
required_test_file="Tests/ScriptoriaCoreTests/Flow/FlowDatabaseMigrationTests.swift"
if [ ! -f "$required_test_file" ]; then
  echo "[flow-db] Flow schema exists but missing required migration test file: $required_test_file"
  exit 1
fi

required_scenarios=(
  "fresh install"
  "upgrade"
  "backfill"
  "rollback"
  "idempotent"
)

for scenario in "${required_scenarios[@]}"; do
  if ! rg -qi "$scenario" "$required_test_file"; then
    echo "[flow-db] Missing migration scenario marker in $required_test_file: $scenario"
    exit 1
  fi
done

echo "[flow-db] Running flow migration test suite..."
swift test --filter FlowDatabaseMigrationTests

echo "[flow-db] Flow DB migration checks passed."
