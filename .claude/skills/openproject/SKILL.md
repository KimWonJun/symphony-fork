---
name: openproject
description: Query and mutate OpenProject work packages via its REST API v3 using curl and the OPENPROJECT_API_KEY environment variable.
---

# OpenProject REST API v3

## Prerequisite

`OPENPROJECT_API_KEY` and `OPENPROJECT_URL` are exported in this session's
environment (inherited from the Symphony orchestrator). Authentication is
HTTP Basic with the literal username `apikey`.

## Read a work package

```bash
curl -s -u "apikey:$OPENPROJECT_API_KEY" "$OPENPROJECT_URL/api/v3/work_packages/37"
```

The response includes `lockVersion` (needed for every update) and
`_links.status.title` (current state).

## Change the status (ALWAYS read lockVersion first)

OpenProject uses optimistic locking.
> NOTE: WP 응답에 embedded 리소스의 lockVersion이 함께 올 수 있으므로 lockVersion은 반드시 위처럼 최상위 JSON에서 python으로 읽는다(grep 금지).
 Updates without the current
`lockVersion` fail; a 409 means someone updated the work package after your
read — re-read and retry once.

```bash
# 1. Read current lockVersion
LOCK=$(curl -s -u "apikey:$OPENPROJECT_API_KEY" "$OPENPROJECT_URL/api/v3/work_packages/37" | python3 -c "import sys,json;print(json.load(sys.stdin)['lockVersion'])")

# 2. Resolve the target status id (statuses are stable; cache mentally)
curl -s -u "apikey:$OPENPROJECT_API_KEY" "$OPENPROJECT_URL/api/v3/statuses" | grep -o '{"_type":"Status"[^}]*}' | grep -o '"id":[0-9]*,"name":"[^"]*"'

# 3. PATCH with lockVersion + status href
curl -s -X PATCH -u "apikey:$OPENPROJECT_API_KEY" \
  -H "Content-Type: application/json" \
  "$OPENPROJECT_URL/api/v3/work_packages/37" \
  -d "{\"lockVersion\": $LOCK, \"_links\": {\"status\": {\"href\": \"/api/v3/statuses/7\"}}}"
```

- Check the response for `"_type":"Error"`; `UpdateConflict` = stale
  lockVersion → re-read and retry once.

## Comment (workpad)

```bash
curl -s -X POST -u "apikey:$OPENPROJECT_API_KEY" \
  -H "Content-Type: application/json" \
  "$OPENPROJECT_URL/api/v3/work_packages/37/activities" \
  -d '{"comment": {"raw": "## Agent Workpad\n\n- [ ] plan item"}}'
```

Workpad convention on OpenProject: comment editing may be restricted by
permissions, so maintain the workpad in **append mode** — post a new comment
titled `## Agent Workpad (update N)` for each significant progress update
instead of editing one comment.

## List project work packages by status

```bash
curl -s -u "apikey:$OPENPROJECT_API_KEY" \
  "$OPENPROJECT_URL/api/v3/projects/crypto-server/work_packages?filters=%5B%7B%22status%22%3A%7B%22operator%22%3A%22%3D%22%2C%22values%22%3A%5B%227%22%5D%7D%7D%5D"
```

(`filters` is URL-encoded JSON: `[{"status":{"operator":"=","values":["7"]}}]`.)
