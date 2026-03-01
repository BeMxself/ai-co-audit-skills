---
name: implementation-audit-kiro
description: Sync and run the implementation-audit-kiro automation scripts in a project using kiro-cli + codex. Supports init, run, continue, and manual resume from phase.
user_invocable: true
argument: "<action and args>"
---

# Implementation Audit Skill (Kiro CLI)

This skill installs/syncs implementation-audit-kiro automation assets into the current project, prepares a Kiro agent in the target project, then runs the workflow.

## Path Model

- `PROJECT_ROOT`: current working directory.
- `SKILL_DIR`: directory containing this `SKILL.md`.
- `PROJECT_REFERENCE_DIR`: `${PROJECT_ROOT}/skills/implementation-audit-kiro/automation-ref`.
- `SKILL_REFERENCE_DIR`: `${SKILL_DIR}/automation-ref`.
- `FALLBACK_SOURCE_DIR`: `${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-$HOME/Projects/ai-co-audit-skills}`.
- `FALLBACK_REFERENCE_DIR`: `${FALLBACK_SOURCE_DIR}/skills/implementation-audit-kiro/automation-ref`.
- `REFERENCE_DIR`: resolved source directory.
- `TARGET_DIR`: `${PROJECT_ROOT}/automation/implementation-audit-kiro`.

Resolve `REFERENCE_DIR` before Step 1:

```bash
PROJECT_REFERENCE_DIR="${PROJECT_ROOT}/skills/implementation-audit-kiro/automation-ref"
SKILL_REFERENCE_DIR="${SKILL_DIR}/automation-ref"
FALLBACK_SOURCE_DIR="${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-$HOME/Projects/ai-co-audit-skills}"
FALLBACK_REFERENCE_DIR="${FALLBACK_SOURCE_DIR}/skills/implementation-audit-kiro/automation-ref"

if [[ -d "${PROJECT_REFERENCE_DIR}" ]]; then
  REFERENCE_DIR="${PROJECT_REFERENCE_DIR}"
elif [[ -d "${FALLBACK_REFERENCE_DIR}" ]]; then
  REFERENCE_DIR="${FALLBACK_REFERENCE_DIR}"
else
  REFERENCE_DIR="${SKILL_REFERENCE_DIR}"
fi
```

## Step 1: Sync Automation Assets

If `${TARGET_DIR}/sync-automation.sh` is missing, copy it from reference first:

```bash
mkdir -p automation/implementation-audit-kiro
cp "${REFERENCE_DIR}/sync-automation.sh" automation/implementation-audit-kiro/sync-automation.sh
chmod +x automation/implementation-audit-kiro/sync-automation.sh
```

Run sync check:

```bash
bash automation/implementation-audit-kiro/sync-automation.sh "${REFERENCE_DIR}" "${TARGET_DIR}"
```

`sync-automation.sh` resolves cache-style reference paths to a non-cache source automatically. If auto-resolution fails, set `AI_CO_AUDIT_SKILLS_SOURCE_DIR` to your `ai-co-audit-skills` checkout root and run again.

If exit code is `1`, show `[MISS]` / `[DIFF]` items and ask user whether to force sync. If user agrees:

```bash
bash automation/implementation-audit-kiro/sync-automation.sh "${REFERENCE_DIR}" "${TARGET_DIR}" --auto-copy
```

## Step 2: Configure Kiro Agent in Target Project

Write the Kiro agent profile to the target project:

```bash
bash automation/implementation-audit-kiro/setup-kiro-agent.sh \
  --project-root "${PROJECT_ROOT}" \
  --agent-name "ai-co-audit-kiro-opus" \
  --model "claude-opus-4.6"
```

If the file already exists and user confirms overwrite, append `--force`.

## Step 3: Execute User Intent

### Init Task

```bash
bash automation/implementation-audit-kiro/init.sh --input <file> [--input <file> ...] [--prompt "..."] [--final-report-path <relative-path>] [--kiro-agent <agent-name>]
```

Kiro version defaults:
- It writes `agents.claude.command` in task config to a `kiro-cli` command.
- Default command pattern:
  `prompt="$(cat)"; kiro-cli chat --agent "<agent-name>" --no-interactive --trust-all-tools "$prompt"`
- Default `--kiro-agent` is `ai-co-audit-kiro-opus`.
- Task metadata generation uses local fallback by default (no Claude dependency).

### Run Task

```bash
.ai-workflows/<task-id>/run
```

`run` reads task config first, prints plugin version, then asks for one-time confirmation in interactive terminals (`y` to continue). In non-interactive terminals, it auto-continues.

### Continue Task

```bash
.ai-workflows/<task-id>/continue
```

### Continue from Specific Phase

```bash
.ai-workflows/<task-id>/continue --from-phase <phase> [--from-round <n>]
```

Valid phases:
- `initial-claude`
- `initial-codex`
- `compare-claude`
- `compare-codex`
- `merge-claude`
- `round-codex`
- `round-claude`
- `completed`

## Notes

- This skill is for `kiro-cli` execution flow and should not be mixed with Claude Code slash-command usage.
- Required tools in target project terminal: `kiro-cli`, `codex`, `jq`, `timeout`.
- `init` must remain non-interactive.
- `run` may ask one startup confirmation in interactive terminals; non-interactive terminals must auto-continue.
- Keep workflow files under `.ai-workflows/<task-id>/`.
- `--final-report-path` must be relative to `workingDirectory`.
