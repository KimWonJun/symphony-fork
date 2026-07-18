---
name: debug
description:
  Investigate stuck runs and execution failures by tracing Symphony and Claude
  Code adapter logs with issue/session identifiers; use when runs stall, retry
  repeatedly, or fail unexpectedly.
---

# Debug

## Goals

- Find why a run is stuck, retrying, or failing.
- Correlate Linear issue identity to a Claude session quickly.
- Read the right logs in the right order to isolate root cause.

## Log Sources

- Primary runtime log: `log/symphony.log`
  - Default comes from `SymphonyElixir.LogFile` (`log/symphony.log`).
  - Includes orchestrator, agent runner, and Claude Code adapter lifecycle logs.
- Rotated runtime logs: `log/symphony.log*`
  - Check these when the relevant run is older.

## Correlation Keys

- `issue_identifier`: human ticket key (example: `MT-625`)
- `issue_id`: Linear UUID (stable internal ID)
- `session_id`: Claude session-turn pair (`<claude_session_id>#t<turn>`)

`elixir/docs/logging.md` requires these fields for issue/session lifecycle logs. Use
them as your join keys during debugging.

## Quick Triage (Stuck Run)

1. Confirm scheduler/worker symptoms for the ticket.
2. Find recent lines for the ticket (`issue_identifier` first).
3. Extract `session_id` from matching lines.
4. Trace that `session_id` across start, stream, completion/failure, and stall
   handling logs.
5. Decide class of failure: timeout/stall, turn spawn/startup failure, turn
   failure, or orchestrator retry loop.

## Commands

```bash
# 1) Narrow by ticket key (fastest entry point)
rg -n "issue_identifier=MT-625" log/symphony.log*

# 2) If needed, narrow by Linear UUID
rg -n "issue_id=<linear-uuid>" log/symphony.log*

# 3) Pull session IDs seen for that ticket
rg -o "session_id=[^ ;]+" log/symphony.log* | sort -u

# 4) Trace one session end-to-end
rg -n "session_id=<claude_session_id>#t<turn>" log/symphony.log*

# 5) Focus on stuck/retry signals
rg -n "Issue stalled|scheduling retry|turn_timeout|claude_turn_error|claude_exited|Agent run failed" log/symphony.log*
```

## Investigation Flow

1. Locate the ticket slice:
    - Search by `issue_identifier=<KEY>`.
    - If noise is high, add `issue_id=<UUID>`.
2. Establish timeline:
    - Identify first `Claude turn started ... session_id=...` for the earliest
      turn.
    - Follow with `Completed agent run for ...`, `Agent run failed for ...`, or
      `Agent task exited ...` lines carrying the same `session_id`.
3. Classify the problem:
    - Stall loop: `Issue stalled ... restarting with backoff`.
    - Turn spawn/startup failure: no `Claude turn started` line appears for
      that turn; the reason surfaces via `Agent run failed for ...: <reason>`.
    - Turn execution failure: `claude_turn_error`, `claude_exited`,
      `turn_timeout`, or `stream_ended_without_result` inside an
      `Agent run failed`/`Agent task exited` line.
    - Worker crash: `Agent task exited ... reason=...`.
4. Validate scope:
    - Check whether failures are isolated to one issue/session or repeating across
      multiple tickets.
5. Capture evidence:
    - Save key log lines with timestamps, `issue_identifier`, `issue_id`, and
      `session_id`.
    - Record probable root cause and the exact failing stage.

## Reading Claude Adapter Session Logs

Claude adapter logs are traced in `log/symphony.log*` via the
`Claude turn started`/`session_id=<uuid>#t<n>` patterns. Diagnostics are
emitted into `log/symphony.log` and keyed by `session_id`. Read them as a
lifecycle:

1. `Claude turn started for issue_id=... issue_identifier=... turn=<n>
   resume=<id|new>`
2. Turn stream/lifecycle events for the same `session_id` (surfaced through
   the orchestrator's generic `Agent task ...` lines; there is no separate
   Claude-specific completion log line at the adapter layer)
3. Terminal event:
    - `Completed agent run for ... session_id=...` (success), or
    - `Agent run failed for ...: <reason>` / `Agent task exited ...
      reason=...` (error), or
    - `Issue stalled ... restarting with backoff` (stall recovery)

For one specific session investigation, keep the trace narrow:

1. Capture one `session_id` (`<claude_session_id>#t<turn>`) for the ticket.
2. Build a timestamped slice for only that session:
    - `rg -n "session_id=<claude_session_id>#t<turn>" log/symphony.log*`
3. Mark the exact failing stage:
    - Startup/spawn failure before any stream events (no `Claude turn started`
      line for that turn; reason surfaces via `Agent run failed ...`).
    - Turn/runtime failure after stream events (`claude_turn_error`,
      `claude_exited`, `turn_timeout`, `stream_ended_without_result`).
    - Stall recovery (`Issue stalled ... restarting with backoff`).
4. Pair findings with `issue_identifier` and `issue_id` from nearby lines to
   confirm you are not mixing concurrent retries.

Always pair session findings with `issue_identifier`/`issue_id` to avoid mixing
concurrent runs.

## Notes

- Prefer `rg` over `grep` for speed on large logs.
- Check rotated logs (`log/symphony.log*`) before concluding data is missing.
- If required context fields are missing in new log statements, align with
  `elixir/docs/logging.md` conventions.
