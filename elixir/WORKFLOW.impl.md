---
tracker:
  kind: openproject
  endpoint: "http://op.cloudsec.lan"
  project_slug: "ini-cnapp"
  assignee: "me"
  required_labels: []
  active_states:
    - Confirmed
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
---
# 2차 작업: 구현

사람이 1차 계획서를 검토·승인했다. `## Target Modules`의 레포들이 워크스페이스 하위에
워크트리로 준비되어 있다 (브랜치 `feature/op-<WP번호>`).

**description의 `## Implementation Plan` 이 이번 작업의 명세다.** 사람이 1차 계획을 수정했을
수 있으므로, 워크패드가 아니라 **현재 description의 계획서를 정본으로** 따른다.

{% if attempt %}
재시도 #{{ attempt }} 이다. 워크스페이스의 현재 상태에서 이어서 진행하고, 이미 끝낸
조사·검증을 반복하지 않는다.
{% endif %}

## 시작 전: Decisions Needed 확인 (게이트)

`## Implementation Plan` 의 `### Decisions Needed` 를 먼저 읽는다.

- `- 없음` 이면 그대로 진행한다.
- 결정이 있으면 **각 `- [ ] **D<n>:**` 가 `- [x]` 로 체크됐고, 옵션형은 하위 옵션 하나가
  `- [x]` 이거나 `답변:` 이 채워졌는지** 확인한다.
- **미결(D 항목이 여전히 `- [ ]`)이 하나라도 있으면 구현하지 않는다.** 워크패드에
  "미결 결정 Dn 때문에 대기"를 기록하고, status 를 `Specified` 로 되돌린 뒤 종료한다.
  추측으로 결정을 대신하지 말 것 — 그것이 이 게이트의 존재 이유다.
- 사람이 고른 답을 그대로 따른다. 사람 선택이 계획서의 다른 부분(대상 레포·수정 지점)과
  어긋나면, 사람 선택을 우선하고 그 차이를 워크패드에 적은 뒤 진행한다.

## 절차

1. 픽업 즉시 status를 In progress(/api/v3/statuses/231)로 전환한다(자기 봇 유지, lockVersion
   먼저 읽기).
2. description의 `## Implementation Plan`(확정된 결정 포함) 과 최신 `## Agent Workpad`
   코멘트를 읽는다. 계획서가 정본이고, 워크패드는 1차 분석 근거다.
3. 새 워크패드 코멘트로 이번 턴의 실행 계획을 먼저 남긴다.
4. **재현 우선** — 계획서의 "재현 확인" 항목대로, 코드를 고치기 전에 현재 동작을 확인한다.
5. 계획서의 "수정 지점"대로 구현한다. 여러 워크트리에 걸친 변경이면 레포마다 커밋을 나눈다.
6. **검증은 계획서의 "검증 / 테스트" 항목을 그대로 실행한다.** 빌드·테스트 명령을 돌리고,
   추가 테스트를 작성하고, 수용 기준을 하나씩 확인한다. 결과(통과 수·실패 수)를 워크패드에
   증거와 함께 기록한다 — "통과했다"는 주장만 남기지 말 것.
7. **커밋까지만 한다. push 하지 않는다.** (테스트 단계이므로 원격에 올리지 않는다.)
8. 완료하면 status를 Developed(/api/v3/statuses/232)로 전환하며, **같은 PATCH에서 assignee를
   test-bot(유저 55, `/api/v3/users/55`)으로 재할당**한다(4봇 핸드오프 — W3가 픽업하도록):
   `{"lockVersion":L,"_links":{"status":{"href":"/api/v3/statuses/232"},"assignee":{"href":"/api/v3/users/55"}}}`
   워크패드에 결과를 기록한다.

## 계획이 틀렸다고 판단되면

구현 중 계획서의 수정 지점·대상 레포가 틀렸음이 드러나면, 임의로 범위를 넓히지 말고:
- 워크패드에 무엇이 왜 달라졌는지 기록
- description의 `## Target Modules` 와 `## Implementation Plan` 을 갱신
- status를 `Specified`로 되돌림 (사람 재검토 → 다음 실행 때 훅이 새 워크트리 생성)

## 범위 밖 개선사항

발견해도 **새 이슈를 만들지 않는다.** 워크패드에 기록만 남긴다.

---

제공된 워크스페이스 안에서만 파일을 수정한다. `~/workspace/` 의 원본 레포는
읽기 전용이다.

최종 메시지는 완료한 작업과 블로커만 보고한다. "사용자 다음 단계"는 포함하지 않는다.
진짜 블로커(필수 권한/시크릿 누락)일 때만 조기 종료한다.
