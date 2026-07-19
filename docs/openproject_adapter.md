# OpenProject Adapter

Symphony can poll and drive OpenProject work packages instead of Linear
issues. Selection is per-workflow via `tracker.kind: openproject`.

## Configuration (WORKFLOW.md front matter)

| Key | Required | Meaning |
| --- | --- | --- |
| `tracker.kind` | yes | `openproject` |
| `tracker.endpoint` | yes | Instance base URL (e.g. `http://localhost:8080`) — the Linear default is rejected |
| `tracker.api_key` | yes | API token; falls back to `OPENPROJECT_API_KEY` env |
| `tracker.project_slug` | yes | Project identifier (e.g. `crypto-server`) |
| `tracker.active_states` | yes | Status *names* (e.g. `["New", "In progress", "Merging", "Rework"]`) |
| `tracker.terminal_states` | yes | e.g. `["Done", "Canceled", "Duplicate", "Rejected", "Closed"]` |

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
