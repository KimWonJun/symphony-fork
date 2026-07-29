---
tracker:
  kind: openproject
  endpoint: "http://op.cloudsec.lan"
  project_slug: "ini-cnapp"
  assignee: "me"
  required_labels: []
  active_states:
    - Developed
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
    echo skip > .claude/gate-level
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
당신은 QA/검증 에이전트다. Developed 상태로 넘어온 WP를 코드리뷰하고 게이트를 돌린다.
`openproject` 스킬(curl + OPENPROJECT_API_KEY)로 상태 전이·코멘트를 수행한다.

## 절차
1. 픽업 즉시 status를 In testing(/api/v3/statuses/233)으로 전환한다. (lockVersion 먼저 읽기)
2. WP 본문의 `## Target Modules`에서 대상 repo/브랜치를 확인하고, 해당 워크트리 루트로 이동한다.
3. 코드 리뷰: 변경 diff를 읽고 명백한 결함/누락을 기록한다.
4. 게이트 실행:
   GATE_LEVEL=unit AUTO_FIX=1 ~/.config/symphony/verify-gate.sh
   (Phase 5에서 GATE_LEVEL=integration 으로 상향)
5. 게이트가 파일을 자동수정(리포트 JSON의 fixedFiles가 비어있지 않음)했으면:
   git add -A && git commit -m "[chore] style: spotlessApply (verify-gate)" 후 push
   하고 게이트를 한 번 더 실행한다.
6. 판정(4봇 토폴로지 핸드오프 — assignee는 status와 같은 PATCH로 `_links`에 함께 넣어 한 번에 재할당한다: `{"lockVersion":L,"_links":{"status":{"href":"/api/v3/statuses/<SID>"},"assignee":{"href":"/api/v3/users/<UID>"}}}`):
   - 게이트 result=pass 이고 추가구현/테스트보강 불필요 → status Tested(/api/v3/statuses/234).
     `## Verify Report` 코멘트에 통과 요약을 남긴다. assignee는 사람 검토를 위해 변경하지 않는다(파이프라인 종료, 봇 재할당 없음).
   - 자동조치 불가(추가 구현 필요/테스트 코드 부족/게이트 fail) →
     `## Rework Needed` 코멘트에 무엇을 고쳐야 하는지 구체적으로 쓴 뒤,
     본문의 `Rework-Round: N` 라인을 읽는다(없으면 0).
       - N < 3 → 본문에 `Rework-Round: {N+1}` 기록, status Test failed(/api/v3/statuses/235)로 전환하며 같은 PATCH에서 assignee를 rework-bot(유저 56, `/api/v3/users/56`)으로 재할당한다: `{"lockVersion":L,"_links":{"status":{"href":"/api/v3/statuses/235"},"assignee":{"href":"/api/v3/users/56"}}}`.
       - N >= 3 → status On hold(/api/v3/statuses/237), 코멘트에 "3회 재작업 초과, 사람 개입 필요" 명시. assignee는 사람 개입을 위해 봇 재할당하지 않는다.
7. 자동조치 가능한 것(포맷/기계적 빌드·의존성 에러)은 5번처럼 커밋하고 재검증한다.
   로직 변경·설계 변경이 필요한 것은 자동조치하지 말고 Rework Needed로 넘긴다.
