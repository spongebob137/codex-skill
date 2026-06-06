---
name: opencode-worker
description: Proactively delegate mechanical coding work from Codex to local worker CLIs, defaulting to Windows Claude Code CLI and optionally OpenCode, in isolated git worktrees. Use when Codex can lower its own context/token/quota usage by handing off search-heavy edits, simple bug fixes, test additions, batch replacements, validation runs, first-pass implementation, or other mechanical tasks for Codex to supervise and review. Also use when the user says to use Claude Code CLI, claude worker, OpenCode/opencode, delegate work, or reduce Codex quota.
---

# OpenCode Worker

Use this skill to reduce Codex quota usage by letting Codex supervise while a local worker CLI performs bounded mechanical work in an isolated git worktree. The default backend is Claude Code CLI on Windows; OpenCode remains available as an explicit fallback.

## Proactive Use

Codex should actively consider this skill when a task is likely to consume substantial Codex context or repeated tool turns but is easy to specify and review. If the task fits, briefly tell the user that the mechanical part is suitable for a Claude Code worker, then invoke the helper without waiting for a separate user command unless the task is high risk.

Use the worker proactively for:

- large codebase search followed by narrow edits
- repetitive file edits or low-level refactors
- writing straightforward tests from clear acceptance criteria
- running and summarizing validation commands
- first-pass implementation where Codex can cheaply review the diff afterward

Do not proactively delegate:

- unclear product or architecture decisions
- security/auth/secret handling
- database schema or migration changes
- production deployment or environment changes
- tasks where the repo is dirty or the worker cannot be safely isolated
- tiny fixes that Codex can complete faster than writing a worker brief

## Delegation Policy

Delegate by default only when the task is mechanical and easy to review:

- repository search and targeted excerpts
- small bug fixes with clear symptoms
- batch edits or repetitive refactors
- adding focused tests for known behavior
- running verification commands and summarizing logs
- producing a first-pass patch for Codex to review

Keep Codex in charge of:

- architecture and cross-module design decisions
- security, auth, secrets, and permissions changes
- database schema changes or migrations
- production deployment or environment changes
- final review, merge decisions, and user-facing conclusions

Do not use this skill when a direct Codex edit is cheaper than delegation, such as a one-line fix already visible in context.

## Workflow

1. Confirm the target repo is a clean git worktree and the requested task is suitable for a worker.
2. Write a compact task brief. Include exact scope, files or modules to inspect, constraints, and expected verification commands. Tell the worker that verification failures are evidence to report, not facts to reclassify as acceptable warnings.
3. Invoke `scripts/invoke-opencode-worker.ps1`. Use `-Backend claude` by default; use `-Backend opencode` only when explicitly needed.
4. Let filtered live worker output stream in the current terminal unless `-NoLiveOutput` is set. Raw worker JSON still goes to logs.
5. Read the final JSON report, `diff_stat`, and targeted diffs for changed files. Avoid loading long logs back into Codex context.
6. Review the worker output. Accept only if the diff is scoped, checks make sense, and no sensitive files were changed.
7. Apply or merge the worker result only after Codex review. The helper never merges into the main worktree automatically.

## Helper Command

Use PowerShell with UTF-8 output:

```powershell
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
& "C:/Users/孙钰涛/.codex/skills/opencode-worker/scripts/invoke-opencode-worker.ps1" `
  -Repo "D:/download/astrbot" `
  -Backend claude `
  -ClaudePath "C:/Users/孙钰涛/AppData/Roaming/npm/claude.cmd" `
  -Model "sonnet" `
  -PermissionMode auto `
  -Task "Inspect the failing test, make the smallest fix, run the relevant test, and summarize the result."
```

Parameters:

- `-Repo`: target git repository path.
- `-Task`: inline worker instructions.
- `-TaskFile`: path to a UTF-8 file containing worker instructions.
- `-Backend`: `claude` by default, or `opencode`.
- `-ClaudePath`: optional explicit path to `claude.cmd`; on Windows prefer `$env:APPDATA/npm/claude.cmd`. The helper skips PowerShell shims such as `claude.ps1` because they cannot be launched directly by `ProcessStartInfo`.
- `-Model`: for Claude defaults to `$env:CLAUDE_WORKER_MODEL` or `sonnet`; for OpenCode defaults to `$env:OPENCODE_WORKER_MODEL` and must be set.
- `-PermissionMode`: Claude permission mode. Defaults to `auto`.
- `-MaxBudgetUsd`: optional Claude budget cap. If unset and `$env:CLAUDE_WORKER_MAX_BUDGET_USD` is unset, the helper does not pass `--max-budget-usd`.
- `-Agent`: OpenCode agent name. Defaults to `build`.
- `-TimeoutSec`: worker timeout in seconds. Defaults to `1800`.
- `-NoLiveOutput`: suppress live streaming and write only logs plus final JSON. Avoid this for first runs or debugging unless the user prefers quiet terminals.
- `-RawLiveOutput`: show raw worker stdout instead of filtered Claude progress summaries. Use this only when diagnosing stream parsing or missing live details.
- `-KeepWorktree`: preserve the worktree for failures or manual inspection.

The helper returns JSON with `run_id`, `backend`, `worker_command`, `worker_exit_code`, `branch`, `worktree`, `changed_files`, `diff_stat`, `log_path`, and `report_path`.

## Review Rules

- Prefer the helper report and diffstat before opening full diffs.
- Inspect only changed files and relevant hunks.
- Reject or rework outputs that touch `.env`, tokens, credentials, auth files, or unrelated modules.
- Reject or rework outputs that turn a failed verification command into an "accepted warning" without Codex making that decision.
- If the worker exits nonzero, treat its output as a draft only.
- If no files changed, do not spend Codex context debugging long logs unless the user asks.
- Keep the worktree until Codex has finished reviewing or transferring the accepted patch.

## Self-Improvement Loop

After any failed or wasteful worker run, Codex should decide whether the skill or helper needs a small update before retrying. Trigger this review for script errors, wrong executable resolution, repeated budget overruns, unclear worker briefs, unsafe or overbroad diffs, or worker conclusions that Codex must reject.

When triggered:

1. State the observed failure mode and the smallest durable improvement.
2. Ask before editing the skill/helper unless the user already requested optimization.
3. Prefer fixing deterministic helper behavior in `scripts/` over adding long prose.
4. Keep `SKILL.md` concise; add only rules that should guide future sessions.
5. Validate edits with PowerShell parsing for scripts and `quick_validate.py` for the skill.
6. Do not rerun an expensive worker just to test a documentation-only tweak unless the user approves.

## Cost Rules

- Use Claude backend by default because the user's Windows OpenCode TUI/CLI may fail on Bun/OpenTUI native DLL loading.
- Do not pass a Claude budget cap by default when the user routes Claude Code to a cheaper third-party model such as ccswitch/Mimo. In that setup, scope, timeout, and review are the useful controls.
- Use `-MaxBudgetUsd` only when the user explicitly asks for a cap, or when using a metered official Claude account where accidental spend matters.
- Treat budget exits as real failed worker runs, not as acceptable warnings.
- Make the outer Codex shell timeout at least 120 seconds longer than `-TimeoutSec`, so the helper can kill the worker and write `report.json` itself.
- Never rely on OpenCode's default model. Require `-Model` or `OPENCODE_WORKER_MODEL` for `-Backend opencode`.

## Visibility Rules

- Default to filtered live output so the user can see Claude Code start, tool calls, concise text, result, and cost.
- Use `-NoLiveOutput` only after the worker path is trusted or when output noise is the bigger cost.
- Use `-RawLiveOutput` for debugging raw stream-json behavior, not for normal development.
