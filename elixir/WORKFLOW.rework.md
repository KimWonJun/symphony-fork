---
tracker:
  kind: openproject
  endpoint: "http://op.cloudsec.lan"
  project_slug: "ini-cnapp"
  assignee: "me"
  required_labels: []
  active_states:
    - Test failed
  terminal_states:
    - Closed
    - Rejected
polling:
  interval_ms: 15000
workspace:
  root: ~/symphony-worktree
hooks:
  after_create: |
    set -eu
    cp -R "${SYMPHONY_CLAUDE_SRC:-$HOME/symphony-fork/.claude}" .claude
    echo unit > .claude/gate-level
  before_run: |
    set -eu
    WPKEY="$(basename "$PWD")"
    WPID="${WPKEY##*-}"
    BASE_DEFAULT="${SYMPHONY_BASE_BRANCH:-develop}"
    BASE_MAP="${SYMPHONY_BASE_BRANCH_MAP:-$HOME/.config/symphony/base-branches}"
    # Keep curl out of the pipe. dash has no pipefail, so a failure inside a
    # pipeline is swallowed and a failed lookup would look like "no modules"
    # (= phase 1), silently skipping worktree creation during phase 2.
    # -f turns HTTP errors into a non-zero exit so we stop right here.
    RESP="$(curl -sf -u "apikey:$OPENPROJECT_API_KEY" \
      "$OPENPROJECT_URL/api/v3/work_packages/$WPID")" || {
      echo "OpenProject lookup failed for WP $WPID" >&2
      exit 1
    }
    DESC="$(printf '%s' "$RESP" | python3 -c 'import sys,json;d=json.load(sys.stdin);print((d.get("description") or {}).get("raw") or "")')"
    # OpenProject normalizes the stored markdown: "-" bullets come back as "*",
    # items get re-indented and separated by blank lines. Accept any CommonMark
    # bullet marker (-, *, +) and any leading indent.
    ENTRIES="$(printf '%s' "$DESC" | awk '
      /^[[:space:]]*##[[:space:]]*Target Modules/ {inblock=1; next}
      /^[[:space:]]*#/ {inblock=0}
      inblock && /^[[:space:]]*[-*+][[:space:]]+/ {
        sub(/^[[:space:]]*[-*+][[:space:]]+/,""); gsub(/[[:space:]]*$/,"");
        gsub(/[`*_]/,"");
        if ($0 != "") { gsub(/[[:space:]]*[@:][[:space:]]*/,"@"); print }
      }
    ')"
    if [ -z "$ENTRIES" ]; then
      echo "No target modules yet - proceeding as phase 1 (analysis)."
      exit 0
    fi
    for ENTRY in $ENTRIES; do
      REPO="${ENTRY%%@*}"
      if [ "$ENTRY" != "$REPO" ]; then
        BASE="${ENTRY#*@}"
        ORIGIN="work package"
      elif [ -f "$BASE_MAP" ] && MAPPED="$(grep -E "^[[:space:]]*$REPO[[:space:]]*=" "$BASE_MAP" 2>/dev/null | grep -v '^[[:space:]]*#' | tail -1 | cut -d= -f2 | tr -d '[:space:]')" && [ -n "$MAPPED" ]; then
        BASE="$MAPPED"
        ORIGIN="repo map"
      else
        BASE="$BASE_DEFAULT"
        ORIGIN="global default"
      fi
      SRC="$HOME/workspace/$REPO"
      if [ ! -d "$SRC/.git" ]; then
        echo "repo not found: $SRC" >&2
        exit 1
      fi
      if [ -d "$PWD/$REPO" ]; then
        echo "worktree exists, skipping: $REPO"
        continue
      fi
      git -C "$SRC" fetch --quiet origin
      if ! git -C "$SRC" show-ref --verify --quiet "refs/remotes/origin/$BASE"; then
        echo "base branch origin/$BASE not found in $REPO (resolved from: $ORIGIN)" >&2
        echo "available: $(git -C "$SRC" branch -r --format='%(refname:short)' | sed 's|origin/||' | tr '\n' ' ')" >&2
        exit 1
      fi
      BR="feature/op-$WPID"
      if git -C "$SRC" show-ref --verify --quiet "refs/heads/$BR"; then
        git -C "$SRC" worktree add "$PWD/$REPO" "$BR"
        echo "worktree ready: $REPO (existing branch $BR)"
      else
        git -C "$SRC" worktree add "$PWD/$REPO" -b "$BR" "origin/$BASE"
        echo "worktree ready: $REPO ($BR from origin/$BASE, via $ORIGIN)"
      fi
    done
agent:
  kind: claude
  max_concurrent_agents: 1
  max_turns: 5
claude:
  command: claude
  model: claude-opus-4-8
  permission_mode: bypassPermissions
  turn_timeout_ms: 3600000
server:
  port: 4001
---

당신은 재작업 에이전트다. Test failed 로 반려된 WP를 고쳐 다시 Developed 로 올린다.
`openproject` 스킬(curl + OPENPROJECT_API_KEY)로 상태 전이·코멘트를 수행한다.

## 절차
1. 픽업 즉시 status를 In progress(/api/v3/statuses/231)로 전환한다(lockVersion 먼저 읽기).
2. WP의 최신 `## Rework Needed` 코멘트를 읽는다. 이것이 재작업 지시의 정본이다.
3. Target Modules의 워크트리로 이동해 지시대로 재작업(추가 구현·테스트 보강)한다.
4. 커밋·push 한다. (세션 종료 시 Layer A Stop 게이트가 unit 레벨로 자동 검증한다.)
5. 완료하면 status를 Developed(/api/v3/statuses/232)로 전환하며, 같은 PATCH에서 assignee를 test-bot(유저 55, `/api/v3/users/55`)으로 재할당한다(4봇 토폴로지 핸드오프 — W3가 재진입해 집도록): `{"lockVersion":L,"_links":{"status":{"href":"/api/v3/statuses/232"},"assignee":{"href":"/api/v3/users/55"}}}`.
   `## Rework Done (round N)` 코멘트에 무엇을 고쳤는지 요약한다.
6. `Rework-Round` 카운터는 건드리지 않는다(W3 테스트가 관리).
