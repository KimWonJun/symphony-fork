# Claude Adapter

Symphony can run its per-issue coding agent on Claude Code instead of the
Codex app-server. Selection is per-workflow via `agent.kind`.

## Configuration (WORKFLOW.md front matter)

| Key | Default | Meaning |
| --- | --- | --- |
| `agent.kind` | `codex` | `claude` switches the execution layer to Claude Code |
| `claude.command` | `claude` | Executable (or wrapper) launched via `bash -lc` in the issue workspace |
| `claude.model` | (CLI default) | Passed as `--model` |
| `claude.model_by_state` | `{}` | Per-issue-state model override; falls back to `claude.model` |
| `claude.permission_mode` | `bypassPermissions` | Passed as `--permission-mode` (`default`, `acceptEdits`, `plan`, `bypassPermissions`) |
| `claude.dangerously_skip_permissions` | `false` | When true, uses `--dangerously-skip-permissions` instead of `--permission-mode` |
| `claude.extra_args` | `""` | Appended verbatim (e.g. `--mcp-config mcp.json --allowedTools "Bash,Edit"`) |
| `claude.turn_timeout_ms` | `3600000` | Per-turn wall clock limit |

### Per-state model overrides

`claude.model_by_state` picks a model from the issue's current state, so a multi-stage
workflow can spend a stronger model where judgement matters and a cheaper one where the
plan is already written:

```yaml
claude:
  model: claude-opus-4-8          # global fallback
  model_by_state:
    "In specification": claude-opus-4-8   # analysis
    "Confirmed": claude-sonnet-5          # implementation
```

State keys are matched after trimming and lowercasing, so `"Confirmed"`, `"confirmed"`
and `"  CONFIRMED  "` all hit the same entry. A state with no entry falls back to
`claude.model`; when neither is set, no `--model` flag is passed at all and the CLI
default applies. Blank state names and non-string models are rejected at config load.

Only the model varies per state — `permission_mode`, `extra_args` and the rest stay
global.

## How it maps to the Codex flow

- One Symphony turn = one `claude -p --output-format stream-json --verbose`
  invocation; turn 2+ adds `--resume <claude session id>` so the thread
  continues with full context. `agent.max_turns` keeps its meaning.
- The adapter reports **cumulative** token usage per session as a
  `turn/completed` payload, which the orchestrator's existing token
  accounting consumes unchanged (input = `input_tokens` +
  `cache_creation_input_tokens` + `cache_read_input_tokens`).
- Tracker access uses an agent-side skill (curl-based) instead of a Codex
  in-process dynamic tool: `.claude/skills/linear` (`LINEAR_API_KEY`) for
  `tracker.kind: linear`, `.claude/skills/openproject` (`OPENPROJECT_API_KEY`)
  for `tracker.kind: openproject`. Unlike the Codex adapter, which `unset`s
  tracker secret env vars before exec'ing its child process (see
  `docs/openproject_adapter.md`), the Claude adapter only strips
  `ANTHROPIC_API_KEY` — the tracker's API key stays inherited so the skill's
  `curl` calls can authenticate directly.

## Authentication (subscription plan)

The adapter is designed for Claude subscription billing:

- Interactive host: run `claude /login` once with your Pro/Max account.
- Headless host/CI: run `claude setup-token` once, export the printed token
  as `CLAUDE_CODE_OAUTH_TOKEN` for the Symphony process.
- The adapter strips `ANTHROPIC_API_KEY` from the child environment so
  usage can never silently switch to pay-as-you-go API billing.

Note: subscription limits (5-hour window + weekly caps) apply. Lower
`agent.max_concurrent_agents` (1-3 recommended) when running on a
subscription.

## Limitations

- `worker.ssh_hosts` (remote SSH workers) is not supported with
  `agent.kind: claude`; `start_session` returns
  `{:error, {:claude_remote_worker_not_supported, host}}`.
- Codex-specific settings (`codex.*`) are ignored when kind is `claude`.
