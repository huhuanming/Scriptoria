# Flow v1 Examples

This folder provides runnable `flow/v1` examples.

## 1) Local Gate + Script (no agent required)

```bash
scriptoria flow validate ./docs/examples/flow-v1/local-gate-script/flow.yaml
scriptoria flow run ./docs/examples/flow-v1/local-gate-script/flow.yaml
```

## 2) PR Loop (gate -> agent -> gate loop)

Dry-run (deterministic, no real provider required):

```bash
scriptoria flow dry-run \
  ./docs/examples/flow-v1/pr-loop/flow.yaml \
  --fixture ./docs/examples/flow-v1/pr-loop/fixture.success.json
```

Live run (requires configured agent runtime/provider):

```bash
scriptoria flow run ./docs/examples/flow-v1/pr-loop/flow.yaml --var repo=org/repo
```
