# Flow v1 Migration Notes

This note helps migrate from one-shot `scriptoria run` workflows to `scriptoria flow`.

## When to Migrate

Use `flow` when you need:

- Looping gate -> agent -> gate behavior
- Global limits (`max_agent_rounds`, `max_wait_cycles`, `max_total_steps`)
- Deterministic dry-run fixture replay
- Per-state structured logs and transitions

Keep using `scriptoria run` for simple one-shot script execution with optional agent stage.

## Breaking Behavior in `flow/v1`

`run` in `gate/script` only accepts path literals.

Examples:

- Invalid in `flow/v1`: `run: check.sh`, `run: eslint`
- Valid in `flow/v1`: `run: ./check.sh`, `run: ../tools/check.sh`, `run: scripts/check.sh`

If not converted, validation/preflight fails with `flow.path.invalid_path_kind`.

## Path Resolution Rules

- Relative `run` paths are resolved from the flow YAML directory.
- Runtime still re-checks file existence/readability even if compile-time checks are skipped.
- Actual script working directory is the resolved script file's parent directory.

## Suggested Migration Steps

1. Start from current script entrypoint and split it into `gate/script/agent/wait/end` states.
2. Put all existing runtime variables into flow `context`.
3. Add explicit loop boundaries in `defaults`:
   `max_agent_rounds`, `max_wait_cycles`, `max_total_steps`.
4. Validate and compile first:
   `scriptoria flow validate ...`, `scriptoria flow compile ...`.
5. Add a fixture and run `flow dry-run` to validate branch behavior.
6. Roll out with `flow run` and monitor per-step logs.

## Command Mapping

- `scriptoria run <script>` -> `scriptoria flow run <flow.yaml>`
- `--command` semantics remain consistent:
  command queue is consumed only during active agent turns.
- `--var` is available in `flow run` and always injected as string in `v1`.
