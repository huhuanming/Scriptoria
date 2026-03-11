# Scriptoria Flow DSL 设计与实施计划（门控 + Agent + 循环）

## 0. 文档目的

本文件汇总并固化本次讨论的完整方案，目标是让 Scriptoria 支持复杂自动化流程：

- 将脚本、agent、门控拆成可复用子单元
- 支持条件分支与循环
- 支持最大轮次（例如 20 轮）避免无限循环
- 在开发前先定义完整测试用例，覆盖正常与异常路径

本方案面向 CLI 首期落地，后续可扩展到 macOS App 配置界面。

## 0.1 当前实现状态（截至 2026-03-10）

以下内容是设计与实施计划，不代表当前仓库已经实现：

- `scriptoria` CLI 还未注册 `flow` 子命令
- `Sources/ScriptoriaCore` 还没有 `Flow` 运行时实现
- `Tests/ScriptoriaCoreTests` 还没有 Flow 专项测试文件

本文件中的“验收标准”是目标态，不是当前态。

---

## 1. 现状与问题

### 1.1 当前能力（代码现状）

当前核心链路是「一次脚本执行 + 一次 agent 触发判断 + 可选一次 agent 执行」，没有循环控制器：

- 触发模式仅支持 `always` 和 `preScriptTrue`
  - `Sources/ScriptoriaCore/Models/Script.swift`
- 触发判断器是一次性布尔决策
  - `Sources/ScriptoriaCore/Execution/AgentTriggerEvaluator.swift`
- CLI 在脚本成功后最多触发一次 agent
  - `Sources/ScriptoriaCLI/Commands/RunCommand.swift`
- App 侧同样是一次性链路
  - `Sources/ScriptoriaApp/AppState.swift`

### 1.2 目标流程需求（用户示例）

目标流程可抽象为：

1. 先跑脚本检查是否有 eslint issue。
2. 若需要修复，唤醒 agent 修复并输出 PR 链接。
3. 脚本检查 PR 的 CI 和 code review comment。
4. 若全部通过则结束。
5. 若未通过则再次唤醒 agent 修复，再回到脚本检查。
6. 可循环，最大循环次数例如 20 轮。
7. 20 轮内完成则成功，否则失败退出。

---

## 2. 核心设计决策

## 2.1 DSL 形式：YAML + JSON IR（推荐）

采用双层结构：

1. **YAML（人写）**  
用于用户配置复杂流程，可读性高，适合代码审查与维护。

2. **JSON IR（机器执行）**  
由编译器将 YAML 转换为规范化 IR，执行层只依赖 IR，便于校验、审计、回放与兼容升级。

不建议首期自研新的“文本语法 DSL”（如 mini-language），原因：

- 解析器与错误定位成本高
- 长期兼容和迁移复杂
- 工具生态（lint/schema/editor support）弱于 YAML/JSON

## 2.2 流程模型：有限状态机（FSM）

流程统一表示为状态机，`v1` 必须支持以下状态类型：

- `gate`：执行门控脚本并产出决策
- `agent`：唤醒 agent 执行修复或操作
- `wait`：等待一段时间后继续
- `script`：执行普通脚本步骤（非门控语义）
- `end`：终止（success/failure）

循环由“状态跳转 + 计数器”表达，不额外引入复杂循环语法。

## 2.3 门控决策统一协议

`gate` 决策统一为 4 种：

- `pass`：通过，进入成功路径
- `needs_agent`：需要 agent 处理
- `wait`：暂时不可判定，等待后重试
- `fail`：业务失败决策，不直接硬退出；必须按 `on.fail` 分支跳转（通常到 `end(status=failure)`）

补充：

- `gate` 的 `fail` 是业务分支，不是运行时硬失败
- 运行时硬失败（超时、进程退出码异常、上限超限等）由引擎直接 non-zero 结束

---

## 3. 顶层架构

## 3.1 组件分层

1. **Flow DSL 层**
- `FlowYAMLDefinition`
- `FlowValidator`（语法 + 语义校验）

2. **Flow Compiler**
- `FlowCompiler`：YAML -> JSON IR
- 负责默认值填充、表达式标准化、错误定位

3. **Flow Runtime**
- `FlowEngine`：执行状态机
- `GateStepRunner`：执行门控脚本并解析输出
- `AgentStepRunner`：复用 `PostScriptAgentRunner`
- `ScriptStepRunner`：复用 `ScriptRunner`
- `FlowExecutionContext`：保存变量、计数器、上一步结果

4. **CLI 接入**
- `scriptoria flow validate`
- `scriptoria flow compile`
- `scriptoria flow run`
- `scriptoria flow dry-run`

## 3.2 与现有模块关系

- 复用脚本执行器：`ScriptRunner`
- 复用 agent 执行器：`PostScriptAgentRunner`
- 新增流程引擎位于 `ScriptoriaCore`
- CLI 子命令位于 `ScriptoriaCLI/Commands`
- 现有 `scriptoria run` 保持兼容，不强制走 flow

## 3.3 执行器 API 对接前置（v1 必做）

为使 DSL 字段可落地，`v1` 在实现 Flow 之前必须补齐执行器适配能力：

1. `ScriptRunner` 侧（供 `GateStepRunner` / `ScriptStepRunner` 使用）  
需要支持并暴露：

- `args`（额外脚本参数）
- `env`（额外环境变量，覆盖同名键）
- `timeout_sec`（超时后终止进程并返回统一错误）
- `workingDirectory`（由流程引擎显式传入，`v1` 固定为“解析后脚本路径的父目录”）

2. `PostScriptAgentRunner` 侧（供 `AgentStepRunner` 使用）  
需要支持并暴露：

- `timeout_sec`（超时后触发 interrupt；`v1` 固定等待 `10s` grace 窗口后仍未结束则强制失败）
- 统一的中断/超时错误映射（对齐 `flow.agent.interrupted` / `flow.step.timeout`）

3. `Flow` 适配层职责  

- `GateStepRunner` / `ScriptStepRunner` 负责将 DSL 的 `run/args/env/timeout_sec/interpreter` 映射到 `ScriptRunner` 输入
- `AgentStepRunner` 负责将 DSL 的 `model/prompt/timeout_sec` 映射到 `PostScriptAgentRunner`
- `GateStepRunner` / `ScriptStepRunner` 对每次执行均先完成 `run` 路径解析，再将 `workingDirectory` 固定设为该解析后脚本的父目录（与现有 `ScriptRunner` 语义对齐）

说明：如果不先补齐以上 API，DSL 中的 `args/env/timeout_sec` 只能停留在文档层，无法稳定实现。

---

## 4. YAML DSL v1 规范

## 4.1 顶层字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `version` | string | 是 | 固定 `flow/v1` |
| `start` | string | 是 | 起始状态 ID |
| `defaults` | object | 否 | 全局默认策略 |
| `context` | object | 否 | 初始上下文变量 |
| `states` | array<object> | 是 | 有序状态定义列表，元素必须包含唯一 `id` |

补充：

- `v1` 不接受 `states` 为 map 的写法（避免顺序语义歧义）
- `states` 中 `id` 必须唯一

## 4.2 defaults 建议字段

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `max_agent_rounds` | int | 20 | agent 最大轮次 |
| `max_wait_cycles` | int | 200 | 全局 wait 进入次数上限（跨所有 wait 状态累计） |
| `max_total_steps` | int | 2000 | 全局状态步数上限（防任意形态死循环） |
| `step_timeout_sec` | int | 1800 | 单步超时（可覆盖） |
| `fail_on_parse_error` | bool | true | gate 输出解析失败是否立即失败 |

数值约束（`v1` 固定）：

- `max_agent_rounds >= 1`
- `max_wait_cycles >= 1`
- `max_total_steps >= 1`
- `step_timeout_sec >= 1`

## 4.3 状态类型定义

### A. `gate`

必填：

- `type: gate`
- `run`（脚本文件路径，必须可由 `ScriptRunner` 执行）
- `on`（必须覆盖 `pass/needs_agent/wait/fail`；其中 `fail` 为业务分支）

可选：

- `args`（可包含表达式；字面量允许 `string|number|bool`：`number/bool` 在 `compile` 期按 JSON 标量文本转为字符串，`null/array/object` 直接报 `flow.validate.field_type_error`）
- `env`（同 `args` 规则）
- `interpreter`（`auto|bash|zsh|sh|node|python3|ruby|osascript|binary`，默认 `auto`）
- `timeout_sec`
- `parse`（枚举，`v1` 支持：`json_last_line|json_full_stdout`，默认 `json_last_line`）
- `on.parse_error`（当 `fail_on_parse_error=false` 时必填）

数值约束：

- `timeout_sec`（若配置）必须为整数且 `>= 1`

### B. `agent`

必填：

- `type: agent`
- `task`
- `next`

可选：

- `model`
- `counter`（计数器名，默认 `agent_round.<state_id>`）
- `max_rounds`（默认取 `defaults.max_agent_rounds`）
- `prompt`（附加提示）
- `export`（从 agent 输出提取变量到 context）
- `timeout_sec`

数值约束：

- `max_rounds`（若配置）必须为整数且 `>= 1`
- `timeout_sec`（若配置）必须为整数且 `>= 1`

### C. `wait`

必填：

- `type: wait`
- `next`

以下二选一：

- `seconds`
- `seconds_from`（表达式，从 context 读取）

可选：

- `timeout_sec`（覆盖 `defaults.step_timeout_sec`）

数值约束：

- `seconds`（若配置）必须为整数且 `>= 0`
- `timeout_sec`（若配置）必须为整数且 `>= 1`

### D. `script`

必填：

- `type: script`
- `run`（脚本文件路径，必须可由 `ScriptRunner` 执行）
- `next`

可选：

- `args`（可包含表达式；字面量允许 `string|number|bool`：`number/bool` 在 `compile` 期按 JSON 标量文本转为字符串，`null/array/object` 直接报 `flow.validate.field_type_error`）
- `env`（同 `args` 规则）
- `interpreter`（同 `gate`）
- `timeout_sec`
- `export`（从脚本输出提取变量；需满足 6.3 的结构化输出契约）

数值约束：

- `timeout_sec`（若配置）必须为整数且 `>= 1`

### E. `end`

必填：

- `type: end`
- `status`（`success` 或 `failure`）

可选：

- `message`

## 4.4 表达式约定（v1）

统一采用简化 JSONPath 风格字符串（仅取值，不做复杂计算），并固定作用域：

- `$.context.*`：全局上下文（可读写）
- `$.counters.*`：计数器（只读）
- `$.state.<state_id>.last.*`：指定状态最近一次输出（只读）
- `$.prev.*`：上一个已完成状态的输出（只读）
- `$.current.*`：当前状态输出（仅在当前状态 `export` 求值时可用；`v1` 标准形状见 6.4）

示例：

- `$.context.pr_url`
- `$.state.postcheck.last.retry_after_sec`
- `$.current.final.pr_url`
- `$.state.lint_script.last.stdout_last_line`

表达式求值失败规则：

- 若字段是必需值，状态执行失败
- 若字段是可选值，置空并记录警告

`v1` 具体字段必需性见 4.8；未在 4.8 列出的字段不允许使用表达式。

## 4.5 gate 解析失败语义（闭环定义）

`fail_on_parse_error` 的行为在 `v1` 固定如下：

1. `fail_on_parse_error=true`（默认）  
gate 输出不可解析时直接失败终止，错误码 `flow.gate.parse_error`。

2. `fail_on_parse_error=false`  
gate 输出不可解析时不直接失败，转移到 `on.parse_error`。

3. 校验约束  
当 `fail_on_parse_error=false` 时，所有 `gate` 状态必须显式定义 `on.parse_error`，否则 `validate` 失败。

4. 不受此开关影响的失败  
`gate` 脚本进程退出码非 0 仍然是直接失败，不进入 `on.parse_error`。

## 4.6 counter 与轮次语义（闭环定义）

`agent` 计数器在 `v1` 固定如下：

1. 存储位置  
计数器存储在 `$.counters.<name>`。

2. 默认命名  
若未显式配置 `counter`，默认名称为 `agent_round.<state_id>`（每个 agent 状态独立）。

3. 同名共享  
多个 agent 状态若显式使用同一 `counter` 名称，则共享同一全局计数器。

4. 初始化与重置  
所有计数器在 flow run 开始时初始化为 `0`，运行过程中不自动重置。

5. 计数时机  
进入 agent 状态时先计算 `next = current + 1`；若 `next > effective_max_rounds`，直接失败，不执行 agent。

6. `effective_max_rounds` 计算  
`effective_max_rounds = min(state.max_rounds, defaults.max_agent_rounds, cli_cap_if_present)`。

7. 日志口径（`counter.value`）  
运行日志中的 `counter.value` 固定记录“本次 agent 状态生效值”，即第 5 条中的 `next`（增量后值），不是增量前值。

## 4.7 parse 枚举与非法值行为（闭环定义）

`gate.parse` 在 `v1` 只允许以下值：

- `json_last_line`：解析 stdout 最后一个非空行 JSON
- `json_full_stdout`：解析完整 stdout 为 JSON

非法值行为：

- `validate/compile` 阶段直接报错，错误码 `flow.gate.parse_mode_invalid`

## 4.8 表达式字段必需性矩阵（v1 固定）

| 状态类型 | 字段 | 是否允许表达式 | 是否必需成功解析 | 失败行为 |
|---|---|---|---|---|
| `gate` | `args[*]` | 是 | 是 | 状态失败（解析失败 `flow.expr.resolve_error`；类型不匹配 `flow.expr.type_error`） |
| `gate` | `env.<key>` | 是 | 是 | 状态失败（解析失败 `flow.expr.resolve_error`；类型不匹配 `flow.expr.type_error`） |
| `wait` | `seconds_from` | 是 | 是 | 状态失败（`flow.wait.seconds_resolve_error`） |
| `script` | `args[*]` | 是 | 是 | 状态失败（解析失败 `flow.expr.resolve_error`；类型不匹配 `flow.expr.type_error`） |
| `script` | `env.<key>` | 是 | 是 | 状态失败（解析失败 `flow.expr.resolve_error`；类型不匹配 `flow.expr.type_error`） |
| `script` | `export.<key>` | 是 | 是 | 状态失败（`flow.script.export_field_missing`） |
| `agent` | `export.<key>` | 是 | 是 | 状态失败（`flow.agent.export_field_missing`） |

补充：

- `v1` 没有“可选表达式字段”；因此“可选值置空告警”规则在 `v1` 不触发，仅为未来版本保留。
- `seconds_from` 解析后必须是整数秒，且 `>= 0`。否则状态失败。
- `agent.export` / `script.export` 在表达式求值前，先执行结构化输出解析；解析失败分别返回 `flow.agent.output_parse_error` / `flow.script.output_parse_error`。
- `export` 字段“缺失”与“值为 null”语义不同：缺失时报错；值为 `null` 视为合法值并写入 context。

## 4.9 路径解析与存在性规则（v1 固定）

适用于 `gate.run` 与 `script.run`：

1. 绝对路径（以 `/` 开头）  
直接使用。

2. `~` 路径  
先展开为用户 Home 目录，再使用。

3. 相对路径（如 `./scripts/a.sh`、`../tools/b.sh`）  
统一相对于 **flow YAML 文件所在目录** 解析，不相对于当前 shell cwd。

4. 路径字面量判定（消除“路径 vs 命令名”歧义）  
`v1` 中，`run` 仅在满足以下任一条件时才被视为“路径字面量”：

- 以 `/` 开头（绝对路径）
- 以 `~/` 开头（home 路径）
- 以 `./` 或 `../` 开头（显式相对路径）
- 包含 `/`（如 `scripts/check.sh`）

其他形式均视为“命令名/裸 token”并报 `flow.path.invalid_path_kind`。  
示例：`eslint`、`check.sh`（无 `/`）在 `v1` 都是非法写法；应写成 `./check.sh` 或 `scripts/check.sh`。

该规则属于 `v1` 迁移期的显式行为变更；发布文档与迁移指引必须单列说明，避免被误判为回归。

5. 一致性要求  
`validate/compile/run` 必须使用同一解析规则，禁止因入口不同而产生路径语义差异。

6. 存在性检查  
`validate` 与 `compile` 默认检查解析后的 `run` 文件存在且可读取；可通过 CLI `--no-fs-check` 跳过该检查（用于离线编译或跨机器校验）。  
`run` 阶段始终再次检查，若缺失或不可读则以 `flow.path.not_found` 失败。

7. 执行工作目录（`workingDirectory`）  
`gate/script` 状态实际执行时，`workingDirectory` 固定为“解析后脚本路径的父目录”，不使用调用命令时的 shell cwd，也不直接使用 flow 文件目录。  
该规则用于保持与现有 `ScriptRunner` 运行语义一致，避免脚本内相对路径行为漂移。

## 4.10 `--var` 与表达式类型规则（v1 固定）

1. `--var` 注入类型  
`--var key=value` 在 `v1` 一律注入为字符串；不做 JSON 自动解析。

键名规则（`v1` 固定）：

- `key` 必须匹配正则 `^[A-Za-z_][A-Za-z0-9_]*$`
- 不支持点号/括号等嵌套语法；例如 `--var a.b=1` 直接报错（`flow.cli.var_key_invalid`）
- 同一命令行中重复传入同名 `key` 时，按出现顺序“后者覆盖前者”（last wins）

2. `args[*]` / `env.<key>` 字面量类型（非表达式）  
在 YAML 中直接写字面量时，先按 YAML 解析类型，再应用下列规则（是否加引号会影响结果类型）：

- `string`：原样使用
- `number`/`bool`：按 JSON 标量文本转换为字符串（示例：`true -> "true"`、`42 -> "42"`）
- `null`/`array`/`object`：`validate/compile` 失败，错误码 `flow.validate.field_type_error`
- 补充：`"42"`、`"true"` 因为本身是字符串，按 `string` 原样使用

3. `args[*]` / `env.<key>` 表达式结果类型  
最终必须是字符串，转换规则：

- 表达式结果为 `string`：原样使用
- 表达式结果为 `number`/`bool`：按 JSON 标量文本转换为字符串（示例：`true`、`42`、`3.14`）
- 表达式结果为 `null`/`array`/`object`：失败，错误码 `flow.expr.type_error`

4. `wait.seconds_from` 目标类型  
必须解析为整数秒：

- `integer number`：直接使用
- `string` 且匹配十进制整数：解析后使用
- 其他类型或格式：失败，错误码 `flow.wait.seconds_resolve_error`

5. `export` 目标类型  
`agent.export` 与 `script.export` 可写入任意 JSON 值到 `context`，不做字符串化。  
若字段存在且值为 `null`，应按合法值写入 `context.<key> = null`；仅“字段不存在”才触发 `*_export_field_missing`。

## 4.11 状态超时语义（v1 固定）

- `gate/agent/wait/script` 均受“单步超时”约束，统一错误码 `flow.step.timeout`。
- `effective_timeout_sec = state.timeout_sec ?? defaults.step_timeout_sec`。
- `end` 状态不参与超时判定。

`wait` 状态补充规则（`v1` 固定）：

1. 先解析 `wait_seconds`（来自 `seconds` 或 `seconds_from`）。
2. 若 `wait_seconds > effective_timeout_sec`，立即以 `flow.step.timeout` 失败（不进入实际 sleep）。
3. 若 `wait_seconds <= effective_timeout_sec`，执行 `wait_seconds` 的 sleep 后按 `next` 跳转。

## 4.12 Agent 超时与中断窗口（v1 固定）

`agent` 状态超时执行规则：

1. 到达 `effective_timeout_sec`（`state.timeout_sec` 或 `defaults.step_timeout_sec`）时，引擎发送一次 `turn/interrupt`。
2. 发送 interrupt 后进入固定 `10s` grace 窗口（`v1` 常量，不可配置）。
3. 若 grace 期内 agent 完成退出，仍按超时处理，错误码 `flow.step.timeout`。
4. 若 grace 期结束仍未退出，引擎强制终止 provider 进程，并以 `flow.step.timeout` 结束。
5. 仅“用户主动 interrupt”使用错误码 `flow.agent.interrupted`；超时路径不返回该错误码。
6. 若 agent 以失败状态结束（非 timeout / 非用户中断 / 非 export 解析失败），统一错误码为 `flow.agent.failed`。

---

## 5. JSON IR v1 规范（执行层）

编译后的 IR 目标：

- 无歧义
- 默认值已展开
- 跳转目标全解析
- 状态 ID 顺序稳定（便于 diff/golden test）

编译确定性规则（`v1` 固定）：

- `states` 数组顺序严格保持 YAML 中的声明顺序
- JSON 输出采用固定键顺序与固定缩进（canonical formatting）
- 相同输入内容 + 相同编译参数必须得到字节级一致的 IR 输出

`run` 路径在 IR 中的标准化规则（`v1` 固定）：

- 若 YAML 为相对路径输入：输出为“相对于 flow 文件目录”的规范相对路径（去除冗余 `.` 段，统一 `/` 分隔）
- 若 YAML 为绝对路径或 `~/`：输出为规范绝对路径
- 编译阶段不将“路径标准化”与“文件存在性检查”混为一谈；存在性仍按 `--no-fs-check` 规则独立处理

校验策略（`v1` 固定）：

- 不可达状态一律视为校验错误（不是 warning）
- 未知字段默认报错（禁止 silent ignore）
- 所有表达式在 `compile` 阶段做静态可解析性检查（存在性在运行时检查）

示例（节选）：

```json
{
  "version": "flow-ir/v1",
  "start": "precheck",
  "defaults": {
    "max_agent_rounds": 20,
    "max_wait_cycles": 200,
    "max_total_steps": 2000,
    "step_timeout_sec": 1800,
    "fail_on_parse_error": true
  },
  "states": [
    {
      "id": "precheck",
      "kind": "gate",
      "exec": {
        "run": "scripts/check-eslint-issues.sh",
        "args": [],
        "env": {},
        "parse": "json_last_line",
        "timeout_sec": 1800
      },
      "transitions": {
        "pass": "done",
        "needs_agent": "fix",
        "wait": "pre_wait",
        "fail": "done_fail"
      }
    }
  ]
}
```

---

## 6. 门控与 Agent 输出契约

## 6.1 gate 脚本输出契约（强约束）

`gate` 输出解析契约由 `parse` 决定：

1. `parse=json_last_line`  
要求 stdout 最后一个非空行是 JSON 对象（其余日志可在前面行出现）。

2. `parse=json_full_stdout`  
要求完整 stdout（trim 后）是单个 JSON 对象（不允许额外非 JSON 文本）。

无论哪种模式，最终 JSON 对象最少必须包含：

```json
{
  "decision": "needs_agent"
}
```

规则：

- `decision` 必填，值只能是 `pass|needs_agent|wait|fail`
- `reason` 建议填，便于日志与排障
- `retry_after_sec` 仅 `wait` 场景使用（建议提供）
- `pr_url` 可选，可在 precheck 或 agent 后补全
- `meta` 可选，用于携带调试与统计信息
- `decision=fail` 时会走 `on.fail` 业务分支，不是引擎硬失败

## 6.2 agent 输出契约（v1 规则）

`agent` 状态分两类：

1. 未使用 `export`  
可接受自由文本最终输出，不强制结构化 JSON。

2. 使用 `export`  
必须提供结构化最终输出，且 `v1` 约定为“最终消息最后一个非空行是 JSON 对象”。

解析成功后，引擎将该 JSON 对象写入 `$.current.final`，供 `agent.export` 表达式读取（例如 `$.current.final.pr_url`）。

建议字段（示例）：

- `pr_url`
- `summary`
- `changed_files`（可选）

失败语义：

- 若 `export` 存在但最终 JSON 不可解析，状态失败，错误码 `flow.agent.output_parse_error`
- 若 `export` 引用字段不存在，状态失败，错误码 `flow.agent.export_field_missing`
- 若 `export` 引用字段存在但值为 `null`，视为合法并写入 `context`（不报错）

## 6.3 script 输出契约（v1 规则）

`script` 状态分两类：

1. 未使用 `export`  
不要求 stdout 结构化；按现有脚本执行语义运行。

2. 使用 `export`  
要求 stdout 最后一个非空行是 JSON 对象；解析成功后写入 `$.current.final`，供 `script.export` 表达式读取。

失败语义：

- 若 `export` 存在但 stdout 最后一个非空行不可解析为 JSON 对象，状态失败，错误码 `flow.script.output_parse_error`
- 若 `export` 引用字段不存在，状态失败，错误码 `flow.script.export_field_missing`
- 若 `export` 引用字段存在但值为 `null`，视为合法并写入 `context`（不报错）

## 6.4 `$.current` 标准形状（v1 固定）

在 `agent.export` 与 `script.export` 求值期间，`$.current` 统一为：

```json
{
  "final": { "...": "..." }
}
```

其中 `final` 是 6.2 / 6.3 定义的“解析后的结构化 JSON 对象”。  
因此 `v1` 中应使用 `$.current.final.<field>` 访问导出字段，避免“根对象 vs final 包装”歧义。

---

## 7. 循环与计数规则

## 7.1 计数模型

- 仅对 `agent` 状态增量计数（`counter`）
- `wait` 不增加 agent 轮次
- 脚本重检也不增加 agent 轮次
- `max_wait_cycles` 是全局计数（跨所有 wait 状态累计）
- 所有状态进入次数都会计入 `max_total_steps`

## 7.2 终止条件

成功终止：

- 到达 `end(status=success)`
- 或 gate 返回 `pass` 并流转到成功终点

失败终止：

- 业务失败：仅当流程显式跳转到 `end(status=failure)`
- 运行时硬失败：`agent` 轮次超出 `max_rounds`、wait 超限、总步数超限、状态超时、`gate/script` 进程非零退出（`flow.gate.process_exit_nonzero` / `flow.script.process_exit_nonzero`）、agent 常规失败（`flow.agent.failed`）、`agent/script` 结构化输出解析失败（`flow.agent.output_parse_error` / `flow.script.output_parse_error`）、表达式求值失败（关键字段）、`gate` 解析失败且 `fail_on_parse_error=true`、用户主动中断 agent

补充（`v1` 固定）：

- 运行时硬失败不会隐式跳转到某个 `failed` 状态，而是直接结束本次 flow run（non-zero）
- `failed` 状态不是必需项；若需要业务可见失败收敛，需通过显式转移到 `end(status=failure)`
- `agent` 超时路径统一归类为 `flow.step.timeout`（内部 interrupt 仅为超时收敛手段）
- `agent interrupted` 在 `v1` 固定指“用户主动中断”，视为运行时硬失败（non-zero，错误码 `flow.agent.interrupted`）

## 7.3 与用户示例 1~7 的映射

1. `precheck(gate)` 判断是否有 issue。  
2. `needs_agent -> fix(agent)` 修复并导出 PR。  
3. `postcheck(gate)` 检查 CI + review comment。  
4. `pass -> done`。  
5. 未通过则回 `fix(agent)`，再回 `postcheck(gate)`。  
6. 20 轮内通过则成功。  
7. 超过 20 轮仍不通过则失败。  

## 7.4 用户目标示例（完整端到端）

本节给出与你需求一一对应的完整示例，包含：

- Flow YAML 示例
- 两个门控脚本的输出协议示例
- 一条“20 轮内成功”轨迹
- 一条“20 轮失败退出”轨迹

### 7.4.1 Flow YAML 示例（eslint -> agent -> PR 检查循环）

```yaml
version: flow/v1
start: precheck
defaults:
  max_agent_rounds: 20
  max_wait_cycles: 200
  max_total_steps: 2000
  step_timeout_sec: 1800
  fail_on_parse_error: false   # 示例中显式关闭，演示 on.parse_error 分支
context:
  pr_url: null
  repo: "org/repo"

states:
  - id: precheck
    type: gate
    run: ./scripts/check-eslint-issues.sh
    parse: json_last_line
    on:
      pass: done
      needs_agent: fix
      wait: pre_wait
      fail: done_fail
      parse_error: done_fail

  - id: pre_wait
    type: wait
    seconds: 30
    next: precheck

  - id: fix
    type: agent
    task: fix-eslint-and-open-pr
    model: gpt-5.3-codex
    counter: fix_round
    max_rounds: 20
    prompt: |
      Fix eslint issues only.
      If code changes are needed, commit and open/update pull request.
      Return final structured JSON with at least:
      {"pr_url":"...", "summary":"..."}
    export:
      pr_url: "$.current.final.pr_url"
      fix_summary: "$.current.final.summary"
    next: postcheck

  - id: postcheck
    type: gate
    run: ./scripts/check-pr-ci-review.sh
    parse: json_last_line
    args:
      - "$.context.pr_url"
      - "$.context.repo"
    on:
      pass: done
      needs_agent: fix
      wait: post_wait
      fail: done_fail
      parse_error: done_fail

  - id: post_wait
    type: wait
    seconds_from: "$.state.postcheck.last.retry_after_sec"
    next: postcheck

  - id: done
    type: end
    status: success
    message: "CI all green and no blocking code review comments."

  - id: done_fail
    type: end
    status: failure
    message: "Business-level failure branch."
```

### 7.4.2 precheck 门控脚本输出示例

场景 A：没有 eslint 问题，直接结束

```json
{"decision":"pass","reason":"no eslint issues found"}
```

场景 B：发现 eslint 问题，需要 agent 修复

```json
{"decision":"needs_agent","reason":"12 eslint issues found","meta":{"eslint_issue_count":12}}
```

场景 C：检查工具暂时不可用，等待后重试

```json
{"decision":"wait","reason":"eslint service warming up","retry_after_sec":20}
```

场景 D：脚本无法继续（不可恢复）

```json
{"decision":"fail","reason":"workspace not found"}
```

### 7.4.3 postcheck 门控脚本输出示例

场景 A：PR 已通过

```json
{
  "decision":"pass",
  "reason":"all CI checks passed and no blocking review comments",
  "pr_url":"https://github.com/org/repo/pull/123",
  "meta":{"ci":"success","blocking_reviews":0}
}
```

场景 B：CI 仍在运行，先等待

```json
{
  "decision":"wait",
  "reason":"2 checks still in progress",
  "retry_after_sec":60,
  "pr_url":"https://github.com/org/repo/pull/123"
}
```

场景 C：CI 失败或存在 `REQUEST_CHANGES`，需要再次修复

```json
{
  "decision":"needs_agent",
  "reason":"ci failed and 1 blocking review comment",
  "pr_url":"https://github.com/org/repo/pull/123",
  "meta":{"failed_checks":["lint"],"blocking_reviews":1}
}
```

场景 D：`pr_url` 缺失，直接失败

```json
{
  "decision":"fail",
  "reason":"missing pr_url in context"
}
```

### 7.4.4 执行轨迹示例（20 轮内成功）

示例轨迹：

1. 进入 `precheck`，返回 `needs_agent`（发现 12 个 issue）。
2. 进入 `fix` 第 1 轮，agent 输出 `pr_url=https://github.com/org/repo/pull/123`。
3. 进入 `postcheck`，返回 `wait`（CI 未跑完，`retry_after_sec=60`）。
4. 进入 `post_wait`，等待 60 秒。
5. 再进 `postcheck`，返回 `needs_agent`（有 `REQUEST_CHANGES`）。
6. 进入 `fix` 第 2 轮，agent 修复 review comment 并 push。
7. 再进 `postcheck`，返回 `pass`。
8. 跳转到 `done`，流程成功结束（agent 共 2 轮）。

### 7.4.5 执行轨迹示例（超过 20 轮失败）

示例轨迹：

1. `precheck` 返回 `needs_agent`。
2. `fix` 与 `postcheck` 在 `needs_agent` 间反复跳转。
3. 当 `fix_round` 从 20 准备进入 21 时，触发 `max_rounds` 保护。
4. 引擎直接以运行时硬失败结束（non-zero），错误原因为 `flow.agent.rounds_exceeded`。

### 7.4.6 dry-run 夹具示例（用于测试）

可用 fixture 模拟每一步 gate/agent 结果，以便不连接真实 GitHub/CI 即可验证流程：

```json
{
  "states": {
    "precheck": [
      {"decision":"needs_agent","reason":"12 eslint issues found"}
    ],
    "fix": [
      {"status":"completed","final":{"pr_url":"https://github.com/org/repo/pull/123","summary":"round1 fix"}},
      {"status":"completed","final":{"pr_url":"https://github.com/org/repo/pull/123","summary":"round2 fix"}}
    ],
    "postcheck": [
      {"decision":"wait","retry_after_sec":1,"reason":"checks pending"},
      {"decision":"needs_agent","reason":"request changes"},
      {"decision":"pass","reason":"all green"}
    ]
  }
}
```

说明：

- 该夹具应触发“wait -> needs_agent -> pass”的分支覆盖。
- 对应测试可断言最终为 `success` 且 `fix_round == 2`。

## 7.5 统一错误码规范（v1）

为保证实现与测试断言稳定，`v1` 统一错误码如下：

| 分类 | 错误码 | 触发条件 |
|---|---|---|
| validate/compile/runtime-preflight | `flow.validate.schema_error` | 基础 schema 不合法 |
| validate/compile/runtime-preflight | `flow.validate.unknown_field` | 出现未知字段 |
| validate/compile/runtime-preflight | `flow.validate.unreachable_state` | 存在不可达状态 |
| validate/compile/runtime-preflight | `flow.validate.numeric_range_error` | 数值字段越界或类型不符 |
| validate/compile/runtime-preflight | `flow.validate.field_type_error` | 字段字面量类型不被允许（如 `args/env` 为 null/object/array） |
| validate/compile/runtime-preflight | `flow.path.invalid_path_kind` | `run` 不是脚本路径（例如命令名/裸 token）；`flow run` 预检同样返回该错误 |
| validate/compile/runtime-preflight/runtime | `flow.path.not_found` | `run` 路径解析后文件不存在或不可读（`validate/compile` 仅在未启用 `--no-fs-check` 时检查；`flow run` 预检可触发；进入状态机后执行前复检也可触发） |
| validate/compile/runtime-preflight | `flow.gate.parse_mode_invalid` | `gate.parse` 不是支持枚举 |
| runtime | `flow.expr.resolve_error` | 表达式求值失败（通用） |
| runtime | `flow.expr.type_error` | 表达式值类型不符合目标字段要求 |
| runtime | `flow.gate.parse_error` | gate 输出解析失败且 `fail_on_parse_error=true` |
| runtime | `flow.gate.process_exit_nonzero` | gate 进程退出码非 0 |
| runtime | `flow.script.process_exit_nonzero` | script 进程退出码非 0 |
| runtime | `flow.agent.failed` | agent 以失败状态结束（不含 timeout / interrupted / export 解析失败） |
| runtime | `flow.agent.rounds_exceeded` | 超过生效轮次上限 |
| runtime | `flow.wait.cycles_exceeded` | 超过 `max_wait_cycles` |
| runtime | `flow.steps.exceeded` | 超过 `max_total_steps` |
| runtime | `flow.step.timeout` | 任一步骤超时（含 agent：超时后 interrupt + 10s grace 仍统一按 timeout 失败） |
| runtime | `flow.wait.seconds_resolve_error` | `seconds_from` 解析失败 |
| runtime | `flow.agent.output_parse_error` | agent export 需要 JSON 但输出不可解析 |
| runtime | `flow.script.output_parse_error` | script export 需要 JSON 但输出不可解析 |
| runtime | `flow.agent.export_field_missing` | agent export 引用字段不存在 |
| runtime | `flow.script.export_field_missing` | script export 引用字段不存在 |
| runtime | `flow.agent.interrupted` | 用户主动中断 agent（v1 固定非零失败） |
| runtime-dry-run | `flow.dryrun.fixture_missing_state_data` | dry-run fixture 缺少被执行状态所需数据 |
| runtime-dry-run | `flow.dryrun.fixture_unknown_state` | dry-run fixture 包含未知状态 ID |
| runtime-dry-run | `flow.dryrun.fixture_unconsumed_items` | dry-run 中已执行状态存在未消费的 fixture 条目 |
| cli-warning | `flow.dryrun.fixture_unused_state_data` | dry-run 中未执行状态存在 fixture 条目 |
| cli | `flow.cli.var_key_invalid` | `--var` 键名不符合 `v1` 规则 |
| cli-warning | `flow.cli.command_unused` | flow 结束时仍有未消费的 `--command` |
| runtime | `flow.business_failed` | 到达 `end(status=failure)` |

## 7.6 `flow run` 预检错误归类口径（v1 固定）

- `flow run` 启动后先执行与 `flow validate` 等价的 preflight（包含路径类型与默认存在性检查）。
- preflight 失败时，不进入状态机；退出码非零；错误归类固定为 `runtime-preflight`，错误码沿用表 7.5（不改码）。
- 因此，7.5 中所有 `validate/compile` 类错误在 `flow run` 路径下都可出现为 `runtime-preflight`。
- 仅 preflight 通过后才进入 runtime 阶段。
- 同一错误码可在不同阶段出现（例如 `flow.path.not_found`），日志必须输出 `phase=runtime-preflight|runtime` 以消除歧义。

---

## 8. CLI 交互设计

## 8.1 命令

1. `scriptoria flow validate <flow.yaml> [--no-fs-check]`
- 只做校验，不执行
- 输出错误位置（状态名、字段、行号）
- 默认执行 `run` 路径存在性检查；可用 `--no-fs-check` 跳过文件系统存在性检查

2. `scriptoria flow compile <flow.yaml> --out <flow.json> [--no-fs-check]`
- 输出规范化 IR
- 用于审计、缓存、回放
- 默认执行 `run` 路径存在性检查；可用 `--no-fs-check` 跳过文件系统存在性检查

3. `scriptoria flow run <flow.yaml> [--var <k=v> ...] [--max-agent-rounds <n>] [--no-steer] [--command <cmd> ...]`
- 执行完整流程
- 支持 `--var k=v` 注入上下文
- 支持 `--max-agent-rounds` 临时覆盖
- 相对 `run` 路径统一按 flow 文件目录解析（与 shell cwd 无关）
- `run` 阶段始终复检脚本路径存在性（不受 `--no-fs-check` 影响）
- 启动执行前先做与 `flow validate` 等价的 preflight 校验；预检失败直接 non-zero 退出
- `--no-steer`：禁用运行期交互式 steer 输入
- `--command`（可重复）：在一次 `flow run` 内先进入 FIFO 队列；仅在存在活动 agent turn 时投递；`/interrupt` 在投递成功后触发用户主动中断
- 参数名与现有 `scriptoria run` 保持一致（统一使用 `--command`，`v1` 不新增 `--agent-command`）

4. `scriptoria flow dry-run <flow.yaml> --fixture <fixture.json>`
- 不调用真实 agent/外部系统
- 用假数据走完整分支，验证状态跳转

## 8.2 参数优先级与 dry-run 规则（v1 固定）

1. `--var` 覆盖优先级  
CLI 传入 `--var key=value` 的优先级高于 YAML `context` 同名键。

类型规则：`--var` 在 `v1` 一律作为字符串注入。

2. dry-run fixture 严格匹配  
- fixture 中缺少被执行状态所需数据：报错退出（`flow.dryrun.fixture_missing_state_data`）  
- fixture 中包含未知状态 ID：报错退出（`flow.dryrun.fixture_unknown_state`）  
- 对“已执行状态”，fixture 条目必须被完全消费；若有剩余未消费条目，报错退出（`flow.dryrun.fixture_unconsumed_items`）  
- 对“未执行状态”，允许存在 fixture 条目，但会打印 warning（`flow.dryrun.fixture_unused_state_data`，不报错）

3. `--max-agent-rounds` 覆盖优先级  
CLI 参数是“全局硬上限”，只允许收紧，不允许放宽。  
最终生效值为 `min(state.max_rounds, defaults.max_agent_rounds, cli_cap_if_present)`。  
若 CLI 值大于配置上限，则按配置上限执行并打印 warning。

4. `--no-fs-check` 行为边界  
- 仅影响 `flow validate` 与 `flow compile` 的“路径存在性”检查  
- 不影响路径语法/路径类型校验（例如命令名仍报 `flow.path.invalid_path_kind`）  
- 不影响 `flow run` 的运行期复检（运行期仍可因路径缺失报 `flow.path.not_found`）

5. `--var` 键名与重复键  
- 键名必须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`，否则报 `flow.cli.var_key_invalid`  
- 不支持 `a.b` 这类嵌套键写法  
- 重复键按“后者覆盖前者”（last wins）

6. steer/interrupt 行为  
- `--no-steer` 仅关闭交互式 stdin steer，不影响 `--command`  
- `--command` 在一次 flow run 内形成“单次消费队列”，生命周期为“run 启动到 run 结束”  
- 当“当前无活动 agent turn”时，命令仅保留在队列中等待后续 turn（不丢弃、不排队到进程外、不立即报错）  
- 每次 agent turn 激活时，引擎按 FIFO 尝试向该 turn 投递队首命令，直到队列清空或该 turn 结束  
- 只有在命令被当前 turn 成功受理（`turn/steer` 请求成功）后才标记为“已消费”；若 turn 提前结束导致未受理，命令保留在队首，待下一次 agent turn 重试  
- 未消费命令可跨多次 agent turn 延续；已消费命令绝不在后续 turn 自动重放（不复用）  
- `--command "/interrupt"` 在投递成功后视为用户主动中断，错误码 `flow.agent.interrupted`  
- 若流程从未进入任何 agent turn，所有 `--command` 视为未消费  
- 如果流程结束时队列仍有未消费命令，打印 warning `flow.cli.command_unused`（不改变退出码）

## 8.3 运行日志字段规范（v1 固定）

- preflight 失败日志必须包含：`phase=runtime-preflight`、`error_code`、`error_message`、`flow_path`
- runtime 每步日志必须包含：`phase=runtime`、`run_id`、`state_id`、`state_type`、`attempt`、`counter`、`decision`、`transition`、`duration`
- `attempt` 取值规则：当前 `state_id` 在本次 run 内的 1-based 进入序号（所有状态都必须给出整数值）
- `counter` 取值规则：`agent` 状态填对象 `{"name":"<counter_name>","value":<post_increment_value>,"effective_max":<limit>}`；其中 `value` 固定为本次生效值（增量后，等于 4.6 中的 `next`）；`gate/script/wait/end` 固定填 `null`
- `decision` 取值规则：`gate` 状态填 `pass|needs_agent|wait|fail|parse_error`；`agent/script/wait/end` 固定填 `null`
- `transition` 取值规则：存在后继跳转时填目标 `state_id`；流程在当前步终止（例如 `end` 或运行时硬失败）时填 `null`
- runtime 失败时，除上述字段外还必须包含：`error_code`、`error_message`
- dry-run 日志口径：`flow dry-run` 的失败日志使用 `phase=runtime-dry-run`，并沿用与 runtime 相同的字段集合与取值规则（含 `attempt/counter/decision/transition` 规则）。

---

## 9. 开发前测试计划（测试先行）

## 9.1 测试分层

1. 单元测试：解析、校验、编译、表达式求值、门控解析
2. 引擎测试：状态机执行和循环策略
3. CLI 集成测试：命令行为与退出码
4. Provider E2E：codex/claude/kimi 全链路
5. 回归测试：现有 run/agent 逻辑不破坏

## 9.2 详细测试用例清单

### A. YAML 解析与语义校验

- `TC-Y01` 最小合法流程可通过
- `TC-Y02` 缺少 `version` 报错
- `TC-Y03` `version` 非 `flow/v1` 报错
- `TC-Y04` 缺少 `start` 报错
- `TC-Y05` `start` 指向不存在状态报错
- `TC-Y06` 状态类型非法报错
- `TC-Y07` `gate.on` 缺少 `pass` 报错
- `TC-Y08` `gate.on` 缺少 `needs_agent` 报错
- `TC-Y09` `gate.on` 缺少 `wait` 报错
- `TC-Y10` `gate.on` 缺少 `fail` 报错
- `TC-Y11` `wait` 同时存在 `seconds` 和 `seconds_from` 报错
- `TC-Y12` `wait` 的 `seconds` 与 `seconds_from` 两者都缺失时报错
- `TC-Y13` `end.status` 非法值报错
- `TC-Y14` 跳转目标不存在报错
- `TC-Y15` 发现不可达状态报错（`v1` 固定），错误码 `flow.validate.unreachable_state`
- `TC-Y16` `max_agent_rounds <= 0` 报错
- `TC-Y17` 当 `fail_on_parse_error=false` 且某 gate 缺少 `on.parse_error` 时报错
- `TC-Y18` `script` 状态缺 `run/next` 时报错
- `TC-Y19` `run` 不是脚本路径（而是内联命令）时报错
- `TC-Y20` `states` 使用 map 结构时报错（`v1` 仅接受数组）
- `TC-Y21` 存在重复 `state.id` 时报错
- `TC-Y22` `gate.parse` 非法枚举值时报错，错误码 `flow.gate.parse_mode_invalid`
- `TC-Y23` 未知字段报错（禁止 silent ignore），错误码 `flow.validate.unknown_field`
- `TC-Y24` `max_wait_cycles <= 0` 报错
- `TC-Y25` `max_total_steps <= 0` 报错
- `TC-Y26` `step_timeout_sec <= 0` 报错
- `TC-Y27` `agent.max_rounds <= 0` 报错
- `TC-Y28` 任意状态 `timeout_sec <= 0` 报错
- `TC-Y29` `wait.seconds < 0` 报错
- `TC-Y30` `wait.seconds` 非整数字面量时报错
- `TC-Y31` `gate.args` 字面量为 `null/array/object` 时报 `flow.validate.field_type_error`
- `TC-Y32` `gate.env` 字面量为 `null/array/object` 时报 `flow.validate.field_type_error`
- `TC-Y33` `script.args/env` 字面量为 `null/array/object` 时报 `flow.validate.field_type_error`
- `TC-Y34` `wait.timeout_sec <= 0` 时报 `flow.validate.numeric_range_error`
- `TC-Y35` 顶层 schema 结构损坏（如 `states` 非数组且字段类型整体不匹配）时报 `flow.validate.schema_error`

### B. YAML -> JSON IR 编译测试

- `TC-C01` 编译产物字段完整
- `TC-C02` 默认值自动注入
- `TC-C03` 状态顺序稳定（确定性输出）
- `TC-C04` 表达式字段保留并标准化
- `TC-C05` 错误信息包含状态名与字段路径
- `TC-C06` golden 文件比对一致
- `TC-C07` canonical 输出键顺序稳定（字节级一致）
- `TC-C08` YAML 中状态声明顺序在 IR 中完全保留
- `TC-C09` 表达式语法非法时在 `compile` 阶段报错
- `TC-C10` 表达式引用作用域前缀非法时报错
- `TC-C11` `run` 路径在 IR 中按规则标准化（相对输入 -> 规范相对路径；绝对输入 -> 规范绝对路径）
- `TC-C12` 相对 `run` 路径按 flow 文件目录解析并写入 IR
- `TC-C13` `run` 为命令名（非路径）时报 `flow.path.invalid_path_kind`
- `TC-C14` `run` 路径不存在且未启用 `--no-fs-check` 时报 `flow.path.not_found`
- `TC-C15` 路径不存在但启用 `--no-fs-check` 时仍可编译成功并产出 IR
- `TC-C16` 启用 `--no-fs-check` 时，`run` 为命令名/裸 token（如 `eslint`、`check.sh`）仍报 `flow.path.invalid_path_kind`
- `TC-C17` 相同 flow 内容在不同 shell cwd 下编译，IR 字节级一致（相对 `run` 场景）
- `TC-C18` `args/env` 字面量为 `number/bool` 时在 IR 中按规则字符串化
- `TC-C19` `wait.timeout_sec` 配置存在时应写入 IR 并参与运行时 `effective_timeout_sec` 计算

### C. 门控输出解析测试

- `TC-GP01` 合法 `pass` 输出
- `TC-GP02` 合法 `needs_agent` 输出
- `TC-GP03` 合法 `wait` + `retry_after_sec`
- `TC-GP04` 合法 `fail` 输出
- `TC-GP05` 非 JSON 行为
- `TC-GP06` JSON 缺 `decision`
- `TC-GP07` `decision` 未知值
- `TC-GP08` `retry_after_sec` 非数字
- `TC-GP09` gate 脚本 exit code 非 0，错误码应为 `flow.gate.process_exit_nonzero`
- `TC-GP10` 解析失败 + `fail_on_parse_error=true` -> 直接失败，错误码 `flow.gate.parse_error`
- `TC-GP11` 解析失败 + `fail_on_parse_error=false` -> 走 `on.parse_error`
- `TC-GP12` `parse=json_full_stdout` 且 stdout 是合法 JSON
- `TC-GP13` `parse=json_full_stdout` 且 stdout 非法 JSON

### D. 引擎状态机测试

- `TC-E01` precheck=pass 直接成功，不启动 agent
- `TC-E02` precheck=needs_agent, postcheck=pass，1轮成功
- `TC-E03` 连续 needs_agent，第 N(<20) 轮成功
- `TC-E04` 连续 needs_agent，第 21 轮失败
- `TC-E05` postcheck=wait，进入等待后重检
- `TC-E06` wait 不增加 agent 轮次
- `TC-E07` wait 循环超限失败（`max_wait_cycles`）
- `TC-E08` agent 常规失败立即失败并返回 `flow.agent.failed`
- `TC-E09` 用户主动 interrupt agent 视为运行时硬失败（non-zero，`flow.agent.interrupted`）
- `TC-E10` 表达式求值失败（关键字段）失败退出，错误码 `flow.expr.resolve_error`
- `TC-E11` `max_rounds == 20` 且第 20 轮通过时应成功
- `TC-E12` `seconds_from` 缺失值时失败
- `TC-E13` `seconds_from = 0` 时不 sleep 且继续跳转
- `TC-E14` `seconds_from < 0` 时失败
- `TC-E15` `step_timeout_sec` 超时行为（含 gate/agent/wait/script）
- `TC-E16` `script` 状态成功路径
- `TC-E17` `script` 状态脚本非 0 退出失败并返回 `flow.script.process_exit_nonzero`
- `TC-E18` `gate <-> script` 环在无 agent/wait 时被 `max_total_steps` 终止
- `TC-E19` `max_wait_cycles` 为全局累计而非按状态独立计数
- `TC-E20` 两个 agent 状态默认计数器互不影响（`agent_round.<state_id>`）
- `TC-E21` 两个 agent 状态显式同名 `counter` 时共享计数
- `TC-E22` 运行时硬失败不会隐式跳转到 `end(status=failure)` 状态
- `TC-E23` 使用 `export` 且 agent 最终输出非 JSON 时失败，错误码 `flow.agent.output_parse_error`
- `TC-E24` 使用 `export` 且字段缺失时失败，错误码 `flow.agent.export_field_missing`
- `TC-E25` `script.export` 引用字段缺失时失败，错误码 `flow.script.export_field_missing`
- `TC-E26` `gate.decision=fail` 必须走 `on.fail` 业务分支（不是硬失败）
- `TC-E27` `max_wait_cycles` 超限返回 `flow.wait.cycles_exceeded`
- `TC-E28` `max_total_steps` 超限返回 `flow.steps.exceeded`
- `TC-E29` 任一步骤超时返回 `flow.step.timeout`
- `TC-E30` 超过 agent 轮次上限返回 `flow.agent.rounds_exceeded`
- `TC-E31` 到达 `end(status=failure)` 返回 `flow.business_failed`
- `TC-E32` `max_wait_cycles == limit` 时第 `limit` 次 wait 仍允许，第 `limit+1` 次失败
- `TC-E33` `max_total_steps == limit` 时第 `limit` 步仍允许，第 `limit+1` 步失败
- `TC-E34` `args/env` 表达式结果为 `null/array/object` 时失败（`flow.expr.type_error`）
- `TC-E35` `seconds_from` 解析为非整数时失败（`flow.wait.seconds_resolve_error`）
- `TC-E36` `args/env` 表达式结果为 `number/bool` 时按规则字符串化
- `TC-E37` 当 `fail_on_parse_error=false` 且 gate 输出不可解析时，状态机必须走 `on.parse_error` 跳转
- `TC-E38` `run` 前校验通过但执行时脚本路径缺失/不可读时，返回 `flow.path.not_found`
- `TC-E39` agent 超时后应发送一次 interrupt，并进入固定 `10s` grace 窗口
- `TC-E40` agent 在 grace 窗口内自行结束时，仍返回 `flow.step.timeout`
- `TC-E41` `agent.export` 字段存在且值为 `null` 时应成功写入 `context`（值为 null）
- `TC-E42` `script.export` 字段存在且值为 `null` 时应成功写入 `context`（值为 null）
- `TC-E43` `wait.seconds > effective_timeout_sec` 时立即返回 `flow.step.timeout`（不进入实际 sleep）
- `TC-E44` `wait.seconds_from` 解析后若大于 `effective_timeout_sec`，返回 `flow.step.timeout`
- `TC-E45` `wait.seconds == effective_timeout_sec` 时允许完成等待并继续跳转
- `TC-E46` 使用 `script.export` 且脚本最后一个非空 stdout 行非 JSON 对象时失败（`flow.script.output_parse_error`）
- `TC-E47` gate 进程非 0 退出时失败并返回 `flow.gate.process_exit_nonzero`

### E. CLI 集成测试

- `TC-CLI01` `flow validate` 成功返回 0
- `TC-CLI02` `flow validate` 非法文件返回非 0
- `TC-CLI03` `flow compile` 成功产出 JSON
- `TC-CLI04` `flow run` 成功路径返回 0
- `TC-CLI05` `flow run` 超轮次返回非 0
- `TC-CLI06` `flow run --max-agent-rounds` 生效并收紧上限
- `TC-CLI07` `flow dry-run` 使用 fixture 正确跳转
- `TC-CLI08` `--var` 覆盖优先级（CLI > YAML context）
- `TC-CLI09` `dry-run` fixture 缺失状态数据时报错，错误码 `flow.dryrun.fixture_missing_state_data`
- `TC-CLI10` `dry-run` fixture 含未知状态数据时报错，错误码 `flow.dryrun.fixture_unknown_state`
- `TC-CLI11` `dry-run` 已执行状态存在剩余未消费条目时报错，错误码 `flow.dryrun.fixture_unconsumed_items`
- `TC-CLI12` `dry-run` 未执行状态存在条目时仅 warning，不报错，warning 码 `flow.dryrun.fixture_unused_state_data`
- `TC-CLI13` `flow run` 单步超时返回非 0 并包含超时状态 ID
- `TC-CLI14` `--max-agent-rounds` 大于配置上限时只告警且不放宽限制
- `TC-CLI15` 业务失败路径退出码非 0 且错误码为 `flow.business_failed`
- `TC-CLI16` `max_total_steps` 超限错误码为 `flow.steps.exceeded`
- `TC-CLI17` `max_wait_cycles` 超限错误码为 `flow.wait.cycles_exceeded`
- `TC-CLI18` `--var key=1` 注入后在表达式中应为字符串 `"1"`（非数字）
- `TC-CLI19` 在不同 cwd 下，`run` 相对路径解析结果一致（相对 flow 文件目录）
- `TC-CLI20` `flow validate --no-fs-check` 在脚本路径缺失时不因存在性检查失败
- `TC-CLI21` `flow compile --no-fs-check` 在脚本路径缺失时仍可产出 IR
- `TC-CLI22` `flow run` 在运行期路径缺失时返回 `flow.path.not_found`
- `TC-CLI23` `--var a.b=1` 因键名非法返回 `flow.cli.var_key_invalid`
- `TC-CLI24` 同一命令行重复 `--var key=...` 时按“后者覆盖前者”生效
- `TC-CLI25` `flow validate --no-fs-check` 时，`run` 为命令名/裸 token 仍返回 `flow.path.invalid_path_kind`
- `TC-CLI26` `flow run` 中 `script` 非 0 退出返回 `flow.script.process_exit_nonzero`
- `TC-CLI27` `flow run` 中 agent 常规失败返回 `flow.agent.failed`
- `TC-CLI28` `flow run --no-steer` 不应进入交互式 stdin 读取
- `TC-CLI29` `flow run --command \"/interrupt\"` 返回 `flow.agent.interrupted`
- `TC-CLI30` `flow run` 预检遇到 `run` 裸 token 时返回 `flow.path.invalid_path_kind` 且不执行状态机
- `TC-CLI31` `flow run --command` 在“无 agent turn”场景下输出 `flow.cli.command_unused` warning
- `TC-CLI32` 多轮 agent 场景下 `--command` 队列按 FIFO 单次消费，不自动重放
- `TC-CLI33` `--command` 在无活动 turn 阶段不丢失，首个 agent turn 激活后开始投递
- `TC-CLI34` 多次进入 agent 状态时，未消费命令可跨 turn 延续；已消费命令不会在后续 turn 自动复用
- `TC-CLI35` 活动 turn 在命令受理前结束时，该命令保持队首并在下一次 agent turn 重试投递
- `TC-CLI36` 流程从未进入 agent 状态时，所有 `--command` 最终都以 `flow.cli.command_unused` warning 输出
- `TC-CLI37` `flow run` 在 `wait` 状态超时时返回 `flow.step.timeout`
- `TC-CLI38` preflight 失败日志必须带 `phase=runtime-preflight`，且不得出现 runtime 步骤字段
- `TC-CLI39` runtime 正常步骤日志必须包含 `phase=runtime` + `run_id/state_id/state_type/attempt/counter/decision/transition/duration`，且非 gate 状态 `decision=null`、非 agent 状态 `counter=null`
- `TC-CLI40` runtime 失败日志必须包含 `phase=runtime` + `error_code/error_message`，且 `state_id` 对齐失败状态；若当前步未产生后继跳转则 `transition=null`
- `TC-CLI41` `flow run` 中 gate 进程非 0 退出返回 `flow.gate.process_exit_nonzero`
- `TC-CLI42` `flow run` preflight 命中路径缺失时返回 `flow.path.not_found`，并输出 `phase=runtime-preflight`（不得进入状态机）
- `TC-CLI43` `flow dry-run` fixture 校验失败日志使用 `phase=runtime-dry-run`，且错误码与 8.2 对应（例如 `flow.dryrun.fixture_missing_state_data`）
- `TC-CLI44` agent 状态日志中 `counter.value` 必须等于本次生效轮次（增量后值），首轮应为 `1`

### F. GitHub PR 门控场景测试（假数据/模拟）

- `TC-PR01` CI 全 success + 无阻塞评论 -> `pass`
- `TC-PR02` CI 有 failure -> `needs_agent`
- `TC-PR03` CI pending -> `wait`
- `TC-PR04` 存在 `REQUEST_CHANGES` -> `needs_agent`
- `TC-PR05` PR URL 缺失 -> `fail`

### G. Provider E2E（按项目要求）

约束：本组用例必须使用 `scriptoria flow run ...` 路径执行，不能用 `scriptoria run ...` 代替。

- `TC-P01` `flow run` + codex 端到端跑通
- `TC-P02` `flow run` + claude adapter 端到端跑通
- `TC-P03` `flow run` + kimi adapter 端到端跑通
- `TC-P04` `flow run` streaming 输出可见
- `TC-P05` `flow run` 运行中可通过交互式 steer 或 `--command` 投递 steer 指令
- `TC-P06` `flow run --command "/interrupt"` 后应以 `flow.agent.interrupted` 非零退出
- `TC-P07` `flow run` task memory 写入 + workspace summarize 正常

### H. 回归测试

- `TC-R01` 现有 `scriptoria run --skip-agent` 行为不变
- `TC-R02` 现有 `preScriptTrue` 触发逻辑不变
- `TC-R03` 既有 schedule/logs/kill 相关命令无回归
- `TC-R04` `flow` 中 `gate/script` 的 `interpreter` 映射到 `ScriptRunner` 输入且行为正确
- `TC-R05` `flow` 中 `gate/script` 实际 `workingDirectory` 固定为“解析后脚本路径父目录”
- `TC-R06` 在不同 shell cwd 下执行同一 flow，`workingDirectory` 行为一致（与 shell cwd 解耦）

---

## 10. 目录与代码落位建议

建议新增目录：

- `Sources/ScriptoriaCore/Flow/`
  - `FlowDefinition.swift`
  - `FlowValidator.swift`
  - `FlowCompiler.swift`
  - `FlowIR.swift`
  - `FlowEngine.swift`
  - `GateStepRunner.swift`
  - `AgentStepRunner.swift`
  - `ScriptStepRunner.swift`
  - `ExpressionEvaluator.swift`
- `Sources/ScriptoriaCLI/Commands/FlowCommand.swift`
- `Tests/ScriptoriaCoreTests/Flow/`
  - `FlowYAMLValidationTests.swift`
  - `FlowCompileTests.swift`
  - `FlowEngineTests.swift`
  - `GateOutputParserTests.swift`
  - `FlowCLITests.swift`
  - `Fixtures/` + `Golden/`

---

## 11. 分阶段实施计划

实施顺序强约束（v1 固定）：

- `M0` 是 `M1~M7` 的硬前置；`M0` 未完成不得开始 `M1` 及后续阶段实现。
- `M0` 完成判定：3.3 中两类执行器 API 与行为全部落地，且对应回归测试为绿灯。

## M0 执行器前置改造（对应 3.3，先做）

- 为 `ScriptRunner` 补齐 `args/env/timeout_sec/workingDirectory` 能力
- 为 `PostScriptAgentRunner` 补齐 `timeout_sec + interrupt grace` 行为与错误映射
- 增加前置回归测试，确保现有 `scriptoria run` 行为不回归
- 前置测试必须显式覆盖：`interpreter` 映射正确、`workingDirectory=脚本父目录`、与 shell cwd 解耦

## M1 规范冻结

- 完成 YAML v1、IR v1、错误码规范
- 定义门控脚本输出协议
- 完成示例流程模板

## M2 测试骨架先行（先红）

- 写完第 9 节全部关键测试
- 跑测试确认失败点符合预期

## M3 编译链路

- 实现 `validate/compile`
- 让 YAML/IR 相关测试先全绿

## M4 运行时引擎

- 实现 `gate/agent/wait/script/end`
- 打通循环与轮次限制

## M5 CLI 对接

- `flow validate/compile/run/dry-run`
- 输出统一日志结构

## M6 集成与回归

- provider E2E
- 既有命令回归

## M7 文档与发布

- 用户文档与模板
- 迁移指引（从一次性 run 到 flow）
- 显式标注路径字面量策略变更：`run: check.sh`/`run: eslint` 在 `v1` 非法，必须改写为 `./check.sh` 或 `scripts/check.sh`

---

## 12. 验收标准

1. 示例流程可在 20 轮内成功结束（exit code 0）。
2. 超过 20 轮自动失败退出（non-zero exit code）。
3. 每轮都有清晰日志（状态、决策、跳转、耗时、原因）。
4. `flow compile` 产物可重复生成且稳定。
5. 所有新增测试通过，既有测试无回归。
6. CLI 中出现 `flow` 子命令且通过基础集成测试。

---

## 13. 风险与应对

1. **风险：gate 脚本输出格式不稳定**  
应对：强制 JSON 契约 + 解析错误即失败（可配置）。

2. **风险：agent 最终输出难以稳定抽取 PR URL**  
应对：要求 agent 输出结构化 JSON，`export` 显式映射。

3. **风险：外部系统（CI/GitHub）短期波动导致误判**  
应对：`wait` 分支 + `retry_after_sec` + `max_wait_cycles`。

4. **风险：流程定义复杂导致排障困难**  
应对：`validate`、`compile`、`dry-run` 三件套和结构化日志。

---

## 14. 业界可借鉴模式（参考）

本方案参考以下成熟编排思想：

- AWS Step Functions 的 `Choice + Wait + Retry/Catch`
- Temporal 的 durable workflow + timer + signal/interrupt
- LangGraph 的递归上限（防无限循环）
- GitHub API 的 PR 检查状态与 review 结果作为 gate 输入

---

## 15. 首期交付边界（建议）

首期（v1）只做最小闭环：

- 状态类型：`gate/agent/wait/script/end`
- 表达式：只支持字段取值（不支持复杂计算）
- 执行存储：先使用现有 run/agentRun 记录 + flow 运行日志
- 恢复能力：先不做 `resume`（次期）

## 15.1 迁移注意事项（v1 必须提示）

- `flow` 的 `run` 字段在 `v1` 只接受“路径字面量”；`check.sh`、`eslint` 这类无 `/` 的裸 token 会报 `flow.path.invalid_path_kind`。
- 迁移时请统一改写为显式路径：`./check.sh`、`../tools/check.sh` 或 `scripts/check.sh`。
- 本条是设计层面的行为变更，不应按回归缺陷处理。

---

## 16. 下一步执行项

1. 在当前分支先实现 M0：补齐 3.3 执行器前置 API 与行为。
2. 再做 M1：冻结 YAML v1 与 IR v1 schema。
3. 先写 M2 测试骨架（覆盖第 9 节所有关键用例），红灯确认后再开始 M3/M4 功能实现。
