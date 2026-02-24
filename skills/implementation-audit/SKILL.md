---
name: implementation-audit
description: Sync and run the implementation-audit automation scripts in a project. Supports init, run, continue, and manual resume from phase.
user_invocable: true
argument: "<action and args>"
---

# Implementation Audit Skill

This skill installs/syncs implementation-audit automation assets into the current project, then runs the workflow.

## Path Model

- `PROJECT_ROOT`: current working directory.
- `SKILL_DIR`: directory containing this `SKILL.md`.
- `PROJECT_REFERENCE_DIR`: `${PROJECT_ROOT}/skills/implementation-audit/automation-ref`.
- `SKILL_REFERENCE_DIR`: `${SKILL_DIR}/automation-ref`.
- `FALLBACK_SOURCE_DIR`: `${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-$HOME/Projects/ai-co-audit-skills}`.
- `FALLBACK_REFERENCE_DIR`: `${FALLBACK_SOURCE_DIR}/skills/implementation-audit/automation-ref`.
- `REFERENCE_DIR`: resolved source directory.
- `TARGET_DIR`: `${PROJECT_ROOT}/automation/implementation-audit`.

Resolve `REFERENCE_DIR` before Step 1:

```bash
PROJECT_REFERENCE_DIR="${PROJECT_ROOT}/skills/implementation-audit/automation-ref"
SKILL_REFERENCE_DIR="${SKILL_DIR}/automation-ref"
FALLBACK_SOURCE_DIR="${AI_CO_AUDIT_SKILLS_SOURCE_DIR:-$HOME/Projects/ai-co-audit-skills}"
FALLBACK_REFERENCE_DIR="${FALLBACK_SOURCE_DIR}/skills/implementation-audit/automation-ref"

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
mkdir -p automation/implementation-audit
cp "${REFERENCE_DIR}/sync-automation.sh" automation/implementation-audit/sync-automation.sh
chmod +x automation/implementation-audit/sync-automation.sh
```

Run sync check:

```bash
bash automation/implementation-audit/sync-automation.sh "${REFERENCE_DIR}" "${TARGET_DIR}"
```

`sync-automation.sh` resolves cache-style reference paths to a non-cache source automatically. If auto-resolution fails, set `AI_CO_AUDIT_SKILLS_SOURCE_DIR` to your `ai-co-audit-skills` checkout root and run again.

If exit code is `1`, show `[MISS]` / `[DIFF]` items and ask user whether to force sync. If user agrees:

```bash
bash automation/implementation-audit/sync-automation.sh "${REFERENCE_DIR}" "${TARGET_DIR}" --auto-copy
```

## Step 2: Execute User Intent

### Init Task

```bash
bash automation/implementation-audit/init.sh --input <file> [--input <file> ...] [--prompt "..."] [--final-report-path <relative-path>]
```

When invoked inside Claude Code:
Run init only, then stop.
Print the user command guide and ask them to execute it in a terminal:
`./.ai-workflows/<task-id>/run`
`./.ai-workflows/<task-id>/continue`
Do not run `run` or `continue` inside Claude Code.

To avoid leaking the output path into task config, `--final-report-path` is embedded into the generated `run`/`continue` scripts as a parameter.

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

- `init` must remain non-interactive.
- `run` may ask one startup confirmation in interactive terminals; non-interactive terminals must auto-continue.
- Keep workflow files under `.ai-workflows/<task-id>/`.
- `--final-report-path` must be relative to `workingDirectory`.
- When running inside Claude Code, avoid calling `.ai-workflows/<task-id>/run` directly since it invokes the `claude` CLI. Use an external terminal or `--dry-run` to generate prompts only.
