---
tracker:
  kind: openproject
  endpoint: "http://op.cloudsec.lan"
  project_slug: "ini-cnapp"
  assignee: "me"
  required_labels: []
  active_states:
    - In specification
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
---
# 1차 작업: 분석 및 구현 계획 수립 (분석 전용)

**이 단계에서는 어떤 코드도 수정하지 않는다.** 목표는 사람이 그대로 검토·수정할 수 있는
**구현 계획서**를 만드는 것이다. 계획서는 세 가지에 답해야 한다:
**(1) 어느 레포를, (2) 무엇을 어떻게 고치고, (3) 고친 뒤 어떻게 검증하는가.**

이 계획서가 이 티켓의 전부다. 사람은 이것만 보고 판단하며, 2차 구현 에이전트도 이것만
보고 작업한다. 따라서 "개요"가 아니라 **그대로 실행 가능한 수준**으로 구체적이어야 한다.

이 티켓은 SE나 QA가 작성했을 수 있어 모듈 정보가 없거나, 있어도 부정확할 수 있다.
티켓에 적힌 모듈명을 그대로 믿지 말고 **코드로 직접 검증**한다.

## 조사 범위

레포지토리 원본은 `~/workspace/` 아래에 있다. **읽기 전용으로만** 접근한다.
현재 워크스페이스에 워크트리가 없는 것은 정상이다.

## 절차

1. 티켓에서 증상, 요구사항, 재현 조건, 에러 메시지, API 경로, 화면명을 추출한다.
2. 그 단서로 `~/workspace/` 를 grep 하여 후보 모듈을 좁힌다.
   API 엔드포인트 경로, 응답 DTO 필드명, 에러 문자열, DB 테이블명이 좋은 단서다.
3. **티켓이 지목한 모듈을 코드로 검증한다.** 티켓 본문이 어떤 레포를 언급하더라도, 실제
   그 레포에 해당 코드가 있는지, 이미 다른 곳으로 이관/폐기되지 않았는지 grep·git log로
   확인한다. 티켓 문구를 근거로 모듈을 확정하지 말 것 — 티켓은 오래됐거나 부정확할 수 있다.
4. 후보가 여러 개면 호출 관계를 따라가 **실제로 수정이 필요한 레포만** 남긴다. 원인은
   A 모듈인데 B 모듈은 호출자일 뿐이라면 B 는 대상이 아니다. 반대로 여러 모듈을 함께
   고쳐야 하면 그렇게 판단한다 — 억지로 하나로 줄이지도, 무관한 레포를 늘리지도 말 것.
5. 각 대상 레포에서 **실제로 수정할 파일과 지점**을 파일 경로:라인 수준으로 특정한다.
6. 검증 방법을 설계한다: 어떤 테스트를 돌리고(기존 테스트 명령 + 추가할 테스트), 무엇을
   재현해 무엇을 확인하면 "고쳐졌다"고 할 수 있는지. 티켓에 `Validation`/`Test Plan`/
   `Testing` 섹션이 있으면 그것을 수용 기준으로 반영한다.
7. 확신이 없거나 사람이 골라야 하는 부분은 추측으로 메우지 말고, 계획서의
   `### Decisions Needed` 에 **사람이 답할 수 있는 결정 항목**으로 남긴다(아래 형식 참고).

## 산출물 1: 워크패드 코멘트 (분석 근거)

분석의 **근거**를 남긴다. 계획서 자체는 산출물 2(description)에 쓰고, 여기에는 그렇게
판단한 이유를 둔다.

- 요구사항/증상 요약
- 근거와 함께 제시한 분석 결과 (파일 경로:라인 인용)
- **후보였으나 제외한 모듈과 그 이유** (예: "티켓은 X 를 언급하나 해당 API 는 이미 Y 로
  이관됨 → X 는 대상 아님")
- 확인하지 못한 부분 / 사람 판단이 필요한 지점

## 산출물 2: description에 구현 계획서 추가

description **끝**에 아래 두 섹션을 이 순서로 추가한다. 이미 있으면 교체한다.
이 두 섹션이 사람의 검토 대상이자 2차 구현의 유일한 입력이다.

### `## Target Modules` (기계가 읽음 — 형식 엄격)

2차 훅이 이 섹션을 파싱해 워크트리를 만든다. 형식이 어긋나면 2차 작업이 실패한다.

```
## Target Modules
- ini-cnapp-alert : stage
- cws-docker : develop
```

- 실제로 **수정할** 레포만 나열한다. 호출자·참고용 레포는 넣지 않는다(그런 맥락은
  `## Implementation Plan` 에 글로 설명한다).
- 항목은 `~/workspace/` 의 디렉터리명과 **정확히** 일치해야 한다.
- 섹션 제목은 반드시 영문 `## Target Modules`. 불릿은 `-`.
- **기준 브랜치**: 모듈 뒤에 `:` 또는 `@` 로 적으면 그 브랜치의 remote(`origin/<브랜치>`)
  에서 분기한다. 생략하면 레포별 기본값이 적용된다. 구분자로 `-` 는 못 쓴다(레포명에
  하이픈). 브랜치명은 `origin/` 접두사 없이. 티켓에 대상 환경이 명시되지 않았으면
  비워두고 추측하지 말 것. 원격에 없는 브랜치를 적으면 2차 훅이 실패한다.

### `## Implementation Plan` (사람이 읽음 — 상세)

레포별로 아래 형식을 채운다. **그대로 실행 가능한 수준**으로 구체적이어야 한다.
"~를 수정한다" 같은 개요가 아니라 어느 파일의 무엇을 어떻게 바꾸는지 적는다.

```
## Implementation Plan

### 배경
- 요구사항 / 문제를 2~3줄로. 왜 이 작업이 필요한가.

### 대상 레포: <레포명>
- 수정 지점:
  - `path/to/File.kt:120` — <무엇을 어떻게>. 근거: <왜 여기인가>
  - `path/to/Other.kt` — <추가/변경할 함수·필드와 시그니처>
- 하지 않을 것: <혼동 방지를 위해 범위 밖으로 명시할 것이 있으면>

### 검증 / 테스트
- 빌드·테스트 명령: `<실제 명령>` (예: `./gradlew ... test`)
- 추가할 테스트: <어떤 케이스를 어디에>
- 재현 확인: 수정 전 <현재 동작>을 확인 → 수정 후 <기대 동작> 확인
- 수용 기준(티켓 Validation/Test Plan 반영): <있으면 체크리스트로>

### Decisions Needed
<!-- 사람이 아래 각 결정에 답한 뒤 Confirmed 로 넘긴다. 2차는 이 답을 읽고 진행한다. -->

- [ ] **D1: <결정 제목>**
  - 배경: <왜 결정이 필요한가 1~2줄>
  - [ ] (a) <옵션 A> — <결과/트레이드오프>
  - [ ] (b) <옵션 B> — <결과/트레이드오프>
  - 추천: <에이전트 추천 옵션과 근거. 없으면 "판단 보류">
  - 답변: <자유 입력이 필요하면 여기에. 옵션 선택이면 위 (a)/(b) 체크>

- [ ] **D2: <결정 제목>**
  - ...
```

**Decisions Needed 규약 (엄격 — 2차가 파싱한다):**

- 각 결정은 `- [ ] **D<번호>: <제목>**` 로 시작한다. 사람이 그 결정을 처리하면
  이 최상위 체크박스를 `- [x]` 로 바꾼다(= "이 결정 확정됨").
- 옵션형 결정은 하위 `- [ ] (a) ...` 중 하나를 사람이 `- [x]` 로 체크한다.
- 자유입력형은 `답변:` 뒤에 사람이 직접 쓴다.
- **에이전트는 답을 채우지 않는다.** 옵션·추천·빈 답변란까지만 만들고 모두 미체크로 둔다.
  추측으로 고르지 말 것 — 고르는 것은 사람의 몫이다.
- 결정이 없으면 이 섹션에 `- 없음` 한 줄만 둔다.

- 레포가 여러 개면 `### 대상 레포:` 블록을 레포마다 반복한다.
- 사람은 이 계획을 UI 에서 직접 수정할 수 있다. 잘못된 지점·빠진 검증을 사람이 고치고,
  `Decisions Needed` 에 답한 뒤 `Confirmed` 로 넘긴다.

## 마지막 단계

두 섹션을 다 쓴 뒤 status를 Specified(/api/v3/statuses/227)로 전환하면서 **같은 PATCH에서
assignee를 impl-bot(유저 54, `/api/v3/users/54`)으로 재할당**한다(4봇 핸드오프 — 사람이
Confirmed로 올리면 W2가 집도록):
`{"lockVersion":L,"_links":{"status":{"href":"/api/v3/statuses/227"},"assignee":{"href":"/api/v3/users/54"}}}`
Symphony가 세션을 종료하고 사람의 검토를 기다린다. 사람이 계획을 확인·수정하고
`Confirmed`로 바꾸면 2차 작업이 시작된다.
