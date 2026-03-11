# Flow GUI TC Mapping

This document maps representative Flow TC groups to GUI surfaces and validation methods.

## Coverage Matrix

| TC Group | Representative TC IDs | GUI Surface | Event Fields | Validation Method |
|---|---|---|---|---|
| `Y` | `TC-Y01`, `TC-Y03`, `TC-Y05` | Validate/Compile panel | `error_code`, `field_path`, `line`, `column` | Validate malformed and valid YAML samples via GUI import + validate |
| `C` | `TC-C01`, `TC-C03`, `TC-C05` | Compile panel + IR preview | `error_code`, `field_path` | Compile to output path and compare canonical JSON preview |
| `E` | `TC-E01`, `TC-E05`, `TC-E10`, `TC-E20`, `TC-E30` | Live Run timeline | `phase`, `state_id`, `decision`, `transition`, `duration` | Run sample flows and verify step sequence and failure rendering |
| `CLI` | `TC-CLI01`, `TC-CLI04`, `TC-CLI10`, `TC-CLI20`, `TC-CLI30` | Run controls + command queue | `action`, `queueDepth`, `reason`, `runId` | Submit command queue, steer/interrupt, and verify queue state changes |
| `GP` | `TC-GP01`, `TC-GP05` | Gate diagnostics card | `decision`, `error_code`, `state_id` | Validate gate parse mode behavior and parse error paths |
| `P` | `TC-P01`, `TC-P03` | Provider diagnostics | `provider`, `model`, `executablePath`, `executableSource` | Execute provider runs and verify metadata persistence in history |
| `PR` | `TC-PR01`, `TC-PR03` | PR loop preset/history | `transition`, `counter`, `warning` | Validate PR scenario path and deterministic state transitions |
| `R` | `TC-R01`, `TC-R04` | Runtime path diagnostics | `workingDirectory`, `state_id`, `error_code` | Validate run path resolution and runtime execution context diagnostics |

## Required Error Codes

- `flow.path.invalid_path_kind`
- `flow.path.not_found`
- `flow.agent.rounds_exceeded`
- `flow.wait.cycles_exceeded`
- `flow.steps.exceeded`
- `flow.step.timeout`
- `flow.gate.process_exit_nonzero`
- `flow.script.process_exit_nonzero`
- `flow.agent.failed`
- `flow.agent.interrupted`
- `flow.business_failed`
- `flow.dryrun.fixture_unknown_state`
- `flow.dryrun.fixture_unconsumed_items`
- `flow.dryrun.fixture_unused_state_data`
