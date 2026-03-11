#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

FLOW_FILE="docs/examples/flow-v1/pr-loop/flow.yaml"
FIXTURE_FILE="docs/examples/flow-v1/pr-loop/fixture.success.json"

if [ ! -f "$FLOW_FILE" ] || [ ! -f "$FIXTURE_FILE" ]; then
  echo "[flow-concurrent] Missing flow example or fixture."
  exit 1
fi

echo "[flow-concurrent] Building CLI binary..."
swift build --product scriptoria >/dev/null

BIN=".build/debug/scriptoria"
if [ ! -x "$BIN" ]; then
  echo "[flow-concurrent] Missing executable: $BIN"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OUT1="$TMP_DIR/run1.log"
OUT2="$TMP_DIR/run2.log"

echo "[flow-concurrent] Running two dry-runs concurrently..."
"$BIN" flow dry-run "$FLOW_FILE" --fixture "$FIXTURE_FILE" >"$OUT1" 2>&1 &
PID1=$!
"$BIN" flow dry-run "$FLOW_FILE" --fixture "$FIXTURE_FILE" >"$OUT2" 2>&1 &
PID2=$!

wait "$PID1"
wait "$PID2"

run_id_1="$( (rg -o 'run_id=[0-9a-fA-F-]+' "$OUT1" || true) | head -n1 | cut -d= -f2 )"
run_id_2="$( (rg -o 'run_id=[0-9a-fA-F-]+' "$OUT2" || true) | head -n1 | cut -d= -f2 )"

if [ -z "$run_id_1" ] || [ -z "$run_id_2" ]; then
  echo "[flow-concurrent] Failed to extract run_id from one or both runs."
  echo "--- run1 ---"
  sed -n '1,120p' "$OUT1"
  echo "--- run2 ---"
  sed -n '1,120p' "$OUT2"
  exit 1
fi

if [ "$run_id_1" = "$run_id_2" ]; then
  echo "[flow-concurrent] Expected distinct run_id values, got same id: $run_id_1"
  exit 1
fi

uniq_ids_run1="$( (rg -o 'run_id=[0-9a-fA-F-]+' "$OUT1" || true) | sort -u | wc -l | tr -d ' ' )"
uniq_ids_run2="$( (rg -o 'run_id=[0-9a-fA-F-]+' "$OUT2" || true) | sort -u | wc -l | tr -d ' ' )"

if [ "$uniq_ids_run1" -ne 1 ] || [ "$uniq_ids_run2" -ne 1 ]; then
  echo "[flow-concurrent] Each run output must contain exactly one unique run_id."
  echo "run1 unique IDs: $uniq_ids_run1"
  echo "run2 unique IDs: $uniq_ids_run2"
  exit 1
fi

phase_lines_1="$( (rg -n '^phase=' "$OUT1" || true) | wc -l | tr -d ' ' )"
phase_lines_2="$( (rg -n '^phase=' "$OUT2" || true) | wc -l | tr -d ' ' )"

if [ "$phase_lines_1" -lt 1 ] || [ "$phase_lines_2" -lt 1 ]; then
  echo "[flow-concurrent] Missing runtime phase lines in one or both outputs."
  exit 1
fi

echo "[flow-concurrent] Concurrent run smoke check passed."
