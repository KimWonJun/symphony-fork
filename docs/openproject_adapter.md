# OpenProject Adapter

Symphony can poll and drive OpenProject work packages instead of Linear
issues. Selection is per-workflow via `tracker.kind: openproject`.

## Tracker behaviour contract

`SymphonyElixir.OpenProject.Adapter` implements the generic
`SymphonyElixir.Tracker` behaviour as a **read-only** adapter: the required
callbacks `fetch_issues_by_states/1` and `fetch_issues_by_ids/1`, plus the
optional `secret_environment_names/1` and `validate_config/1`. It does not
implement `agent_tool_specs/0` or `execute_agent_tool/3` — there is no
in-process OpenProject dynamic tool. All work-package mutations (status
transitions, workpad comments) are agent-side concerns handled by the
`.claude/skills/openproject/SKILL.md` skill (curl + `OPENPROJECT_API_KEY`),
not by the adapter; `SymphonyElixir.OpenProject.Client` keeps those mutation
helpers only for the gated live test.

## Configuration (WORKFLOW.md front matter)

| Key | Required | Meaning |
| --- | --- | --- |
| `tracker.kind` | yes | `openproject` |
| `tracker.endpoint` | yes | Instance base URL (e.g. `http://localhost:8080`) — the Linear default is rejected |
| `tracker.api_key` | yes | API token; falls back to `OPENPROJECT_API_KEY` env |
| `tracker.project_slug` | yes | Project identifier (e.g. `crypto-server`); a top-level tracker key for this kind — `tracker.provider.*` nesting is a linear-specific convention (see `resolve_tracker_secrets/2` in `config/schema.ex`) and is not consumed for `project_slug` resolution here |
| `tracker.active_states` | yes | Status *names* (e.g. `["New", "In progress", "Merging", "Rework"]`) — unlike `linear`/`memory`, there is no built-in default state list |
| `tracker.terminal_states` | yes | e.g. `["Done", "Canceled", "Duplicate", "Rejected", "Closed"]` — same: mandatory, no default |

### `validate_config/1` error atoms

Checked in order; the first failing condition is returned:

| Error atom | Failing condition |
| --- | --- |
| `:missing_openproject_endpoint` | `tracker.endpoint` blank, or equal to the Linear default endpoint |
| `:missing_openproject_api_token` | `tracker.api_key` blank and `OPENPROJECT_API_KEY` unset |
| `:missing_openproject_project` | `tracker.project_slug` blank |
| `:openproject_assignee_filter_not_supported` | `tracker.assignee` is set (unsupported for this kind) |
| `:missing_openproject_active_states` | `tracker.active_states` missing/empty |
| `:missing_openproject_terminal_states` | `tracker.terminal_states` missing/empty |

## Secret advertisement to the agent session

`secret_environment_names/1` returns the tracker's resolved
`secret_environment_names` list — `["OPENPROJECT_API_KEY"]`, plus any
additional env-token name referenced from `tracker.api_key` (e.g.
`$MY_TOKEN_ENV`) — computed once by `Config.Schema.finalize_settings/1` via
`resolve_tracker_secrets/2`. `SymphonyElixir.Tracker.bind_agent_tools/0`
captures this list per session as `dynamic_tool_binding.secret_environment_names`,
and the two agent runtimes treat it differently: under Codex
(`SymphonyElixir.Codex.AppServer`), these names are explicitly `unset` from
the spawned app-server's launch shell/environment, since the adapter exposes
no in-process dynamic tool that would need the raw key. Under Claude
(`SymphonyElixir.Claude.AgentServer`), only `ANTHROPIC_API_KEY` is stripped —
`OPENPROJECT_API_KEY` stays in the spawned `claude` process's inherited
environment so the `openproject` skill's `curl` commands can authenticate
directly.

Environment for the orchestrator process (agents inherit it):

    export OPENPROJECT_API_KEY="<token>"
    export OPENPROJECT_URL="http://localhost:8080"   # used by the agent-side skill

## Semantics and limitations (v1)

- Issue mapping: work package id → `id` ("37") and `identifier` ("WP-37");
  status title → `state`; priority Immediate/High/Normal/Low → 1..4.
- Status filters resolve names to ids via `GET /api/v3/statuses` per poll.
- Updates use optimistic locking: read `lockVersion`, PATCH, retry once on 409.
- Not supported yet: `tracker.assignee` filter (config error), labels
  (`required_labels` must stay `[]`), blocked-by relations.
- OpenProject has no "Todo" status by default — "New" plays that role.

## Local test instance

A podman all-in-one instance is assumed at `http://localhost:8080`
(container `openproject`, project `crypto-server`, custom statuses
Human Review/Merging/Rework added). Live-verify the adapter with:

    SYMPHONY_RUN_LIVE_OPENPROJECT=1 mise exec -- mix test test/symphony_elixir/live_openproject_test.exs
