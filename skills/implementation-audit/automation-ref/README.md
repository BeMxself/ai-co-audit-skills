# AI 实现审计工作流

统一的实现审计自动化流程，支持可配置执行器（runner）：`claude` / `codex` / `kiro` / 自定义命令。

## 脚本说明

- `automation/implementation-audit/setup-kiro-agent.sh`：在目标项目中生成 `.kiro/agents/<agent>.json`
- `automation/implementation-audit/init.sh`：初始化任务目录 `.ai-workflows/<task-id>/`
- `automation/implementation-audit/run-implementation-audit.sh`：执行编排
- `automation/implementation-audit/lib/common.sh`：公共工具
- `automation/implementation-audit/lib/runner.sh`：runner 执行适配

## 快速开始

1) （可选）如果要使用 `kiro` runner，先创建 agent：

```bash
bash automation/implementation-audit/setup-kiro-agent.sh \
  --project-root "$(pwd)" \
  --agent-name ai-co-audit-kiro-opus \
  --model claude-opus-4.6
```

2) 初始化任务：

```bash
bash automation/implementation-audit/init.sh \
  --input docs/plans/2026-02-11-security-external-auth-design.md \
  --reviewer codex \
  --reviser claude
```

3) 运行任务：

```bash
./.ai-workflows/<task-id>/run
```

4) 断点续跑：

```bash
./.ai-workflows/<task-id>/continue
```

## Runner 模型

- `reviewer`：负责每轮评审
- `reviser`：负责初始报告、对比、合并、以及每轮修订（merge 默认由 reviser 执行）

默认值：
- `reviewer=codex`
- `reviser=claude`

可在 `task.json` 设默认，也可通过命令行覆盖：

```bash
./.ai-workflows/<task-id>/run --reviewer codex --reviser kiro
```

优先级：
- CLI > task.json > 内置默认

## task.json 关键字段

```json
{
  "execution": {
    "reviewer": "codex",
    "reviser": "claude"
  },
  "runners": {
    "claude": { "command": "" },
    "codex": { "command": "" },
    "kiro": { "command": "", "agent": "ai-co-audit-kiro-opus" }
  }
}
```

- `runners.<name>.command` 为空时走内置命令适配。
- 自定义 runner 名称可通过 `--runner-cmd <name>=<command>` 在初始化时写入配置。

## 输出文件命名

不再硬编码 `claude/codex` 后缀，统一按当前 runner 名称生成，例如：

- `reports/initial/<reportBaseName>-<reviser>.md`
- `reports/initial/<reportBaseName>-<reviewer>.md`
- `reports/comparison/<reportBaseName>-compare-by-<reviser>.md`
- `reports/rounds/round-04-<reviewer>-review.md`
- `reports/rounds/round-04-<reviser>-revision.md`

## 说明

- `run` / `continue` 会在交互终端先做一次确认输入。
- `kiro` 内置 runner 会在启动前校验 agent 文件是否具备文件读写工具。
- `Ctrl+C` 会中断流程并强制停止正在执行的并行初始任务。
