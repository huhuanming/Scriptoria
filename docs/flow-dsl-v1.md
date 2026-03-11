# Scriptoria Flow DSL v1 Guide

This guide describes the currently implemented `flow/v1` behavior in Scriptoria CLI.

## Commands

```bash
scriptoria flow validate <flow.yaml> [--no-fs-check]
scriptoria flow compile <flow.yaml> --out <flow.json> [--no-fs-check]
scriptoria flow run <flow.yaml> [--var <k=v> ...] [--max-agent-rounds <n>] [--no-steer] [--command <cmd> ...]
scriptoria flow dry-run <flow.yaml> --fixture <fixture.json>
```

Notes:

- `flow run` performs preflight validation before runtime.
- `--no-fs-check` only applies to `validate/compile`.
- `--var` keys must match `^[A-Za-z_][A-Za-z0-9_]*$`.
- Repeated `--var key=...` uses last value.

Example files are available at:

- `docs/examples/flow-v1/local-gate-script/`
- `docs/examples/flow-v1/pr-loop/`

## YAML Shape (`flow/v1`)

Top-level fields:

- `version`: must be `flow/v1`
- `start`: start state id
- `defaults`: optional global limits and policies
- `context`: optional initial context object
- `states`: required array of state objects

Supported state types:

- `gate`
- `agent`
- `wait`
- `script`
- `end`

`run` path rules for `gate/script`:

- Allowed: absolute (`/a/b.sh`), home (`~/a.sh`), explicit relative (`./a.sh`, `../a.sh`), or any token containing `/` (for example `scripts/check.sh`).
- Not allowed: bare command-like tokens (`eslint`, `check.sh`).
- Relative paths are resolved against the flow YAML directory, not shell cwd.

## Minimal Example

```yaml
version: flow/v1
start: precheck
defaults:
  max_agent_rounds: 20
  max_wait_cycles: 200
  max_total_steps: 2000
  step_timeout_sec: 1800
  fail_on_parse_error: true
context:
  pr_url: null
states:
  - id: precheck
    type: gate
    run: ./scripts/precheck.sh
    on:
      pass: done
      needs_agent: fix
      wait: wait_ci
      fail: done_fail
  - id: fix
    type: agent
    task: fix-lint-and-open-pr
    export:
      pr_url: "$.current.final.pr_url"
    next: precheck
  - id: wait_ci
    type: wait
    seconds: 30
    next: precheck
  - id: done
    type: end
    status: success
  - id: done_fail
    type: end
    status: failure
```

## Expressions

Supported roots:

- `$.context.*`
- `$.counters.*`
- `$.state.<state_id>.last.*`
- `$.prev.*`
- `$.current.*` (during `export` evaluation only)

Scalar conversion rules:

- `string` is used as-is.
- `number/bool` become JSON scalar text.
- `null/array/object` are rejected where scalar is required (`args/env` expression targets).

## Runtime Logs

Preflight failure log includes:

- `phase=runtime-preflight`
- `error_code`
- `error_message`
- `flow_path`

Per-step runtime log includes:

- `phase`
- `run_id`
- `state_id`
- `state_type`
- `attempt`
- `counter`
- `decision`
- `transition`
- `duration`

Runtime error steps also include:

- `error_code`
- `error_message`

## Dry-Run Fixture

Fixture file format:

```json
{
  "states": {
    "precheck": [
      {"decision": "needs_agent"}
    ],
    "fix": [
      {"status": "completed", "final": {"pr_url": "https://example.com/pr/1"}}
    ]
  }
}
```

Strictness:

- Missing data for an executed state: `flow.dryrun.fixture_missing_state_data` (error)
- Unknown state in fixture: `flow.dryrun.fixture_unknown_state` (error)
- Unconsumed entries for an executed state: `flow.dryrun.fixture_unconsumed_items` (error)
- Unused entries for non-executed states: `flow.dryrun.fixture_unused_state_data` (warning)

## Common Error Codes

- `flow.validate.schema_error`
- `flow.validate.unknown_field`
- `flow.validate.unreachable_state`
- `flow.validate.numeric_range_error`
- `flow.validate.field_type_error`
- `flow.path.invalid_path_kind`
- `flow.path.not_found`
- `flow.gate.parse_mode_invalid`
- `flow.gate.parse_error`
- `flow.gate.process_exit_nonzero`
- `flow.script.process_exit_nonzero`
- `flow.agent.failed`
- `flow.agent.rounds_exceeded`
- `flow.wait.cycles_exceeded`
- `flow.steps.exceeded`
- `flow.step.timeout`
- `flow.wait.seconds_resolve_error`
- `flow.agent.output_parse_error`
- `flow.script.output_parse_error`
- `flow.agent.export_field_missing`
- `flow.script.export_field_missing`
- `flow.agent.interrupted`
- `flow.business_failed`
- `flow.cli.var_key_invalid`
- `flow.cli.command_unused` (warning)

## TC Mapping Maintenance

To re-generate TC-to-test mapping documentation:

```bash
scripts/generate-flow-tc-mapping.sh
```

Generated file:

- `docs/flow-tc-mapping.md`
