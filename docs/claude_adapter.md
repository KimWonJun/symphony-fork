# Claude Adapter

Symphony can run its per-issue coding agent on Claude Code instead of the
Codex app-server. Selection is per-workflow via `agent.kind`.

## Configuration (WORKFLOW.md front matter)

| Key | Default | Meaning |
| --- | --- | --- |
| `agent.kind` | `codex` | `claude` switches the execution layer to Claude Code |
| `claude.command` | `claude` | Executable (or wrapper) launched via `bash -lc` in the issue workspace |
| `claude.model` | (CLI default) | Passed as `--model` |
| `claude.permission_mode` | `bypassPermissions` | Passed as `--permission-mode` (`default`, `acceptEdits`, `plan`, `bypassPermissions`) |
| `claude.dangerously_skip_permissions` | `false` | When true, uses `--dangerously-skip-permissions` instead of `--permission-mode` |
| `claude.extra_args` | `""` | Appended verbatim (e.g. `--mcp-config mcp.json --allowedTools "Bash,Edit"`) |
| `claude.turn_timeout_ms` | `3600000` | Per-turn wall clock limit |

## How it maps to the Codex flow

- One Symphony turn = one `claude -p --output-format stream-json --verbose`
  invocation; turn 2+ adds `--resume <claude session id>` so the thread
  continues with full context. `agent.max_turns` keeps its meaning.
- The adapter reports **cumulative** token usage per session as a
  `turn/completed` payload, which the orchestrator's existing token
  accounting consumes unchanged (input = `input_tokens` +
  `cache_creation_input_tokens` + `cache_read_input_tokens`).
- Linear access uses the `.claude/skills/linear` skill (curl +
  `LINEAR_API_KEY`) instead of the Codex `linear_graphql` dynamic tool.

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
