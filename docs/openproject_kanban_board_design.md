# OpenProject 칸반 보드 설계

작성일: 2026-07-22
상태: §13의 1~6단계(모니터링: `BoardStore`/`BoardPubSub`/`BoardLive`, 읽기 전용, 드래그 없음) 구현 완료.
      §7~9(쓰기 경로/드래그/확인 모달)는 아직 구현 전.

구현 중 확인된 두 가지 편차:

- §13의 1~4단계(라이브 검증, `fetch_allowed_transitions`, `type_id`, `Tracker` 콜백 2개)와
  `TransitionCache`(§6.2)는 드래그 전용이라 이번 1~6단계 범위에서 스킵함. `BoardStore`는
  `SymphonyElixir.Tracker.fetch_issues_by_states/1`을 그대로 재사용(트래커 무관)하므로 신규
  `Tracker` 콜백이 필요 없었음.
- §5.1의 "OpenProject.Client의 assignee_filter를 상속해 본인 담당 WP만 보인다"는 설명은 실제
  코드와 다름 — `SymphonyElixir.OpenProject.Adapter.validate_config/1`은 assignee가 문자열이면
  `{:error, :openproject_assignee_filter_not_supported}`를 반환한다(OpenProject 트래커는 assignee
  필터를 아예 지원하지 않음). 따라서 보드는 프로젝트의 WP를 전부 보여준다.

## 1. 배경

Symphony는 OpenProject를 트래커로 물고 동작하지만, 두 시스템의 상태를 함께 볼 수단이 없다.

- Symphony TUI는 **현재 작업 중인 WP 번호만** 보여준다. 어떤 WP가 대기 중인지, 방금 끝났는지,
  사람 검토를 기다리는지는 보이지 않는다.
- OpenProject 쪽에서는 Symphony의 실시간 실행 상태를 전혀 알 수 없다. WP 상태만 보인다.
- OpenProject 기본 보드 위젯은 기존 WP를 자동으로 끌어오지 않아 카드를 수동 등록해야 한다.

결과적으로 "지금 무엇이 돌고 있고 무엇이 멈춰 있나"를 알려면 두 화면을 번갈아 봐야 한다.

## 2. 목표와 비목표

### 2.1 목표

- OpenProject 프로젝트의 WP를 상태별 컬럼으로 자동 배치한다. 수동 등록이 없다.
- 각 카드에 Symphony 런타임 상태(running / retry / blocked / 유휴)와 경과시간을 겹쳐 보여준다.
- 드래그앤드롭으로 WP 상태를 실제로 전환한다(양방향).
- OpenProject 워크플로가 허용하지 않는 전이는 화면에서 시도조차 할 수 없게 한다.

### 2.2 비목표

- 에이전트 실시간 출력 스트림(로그 tail) 노출. 별도 이벤트 스트림이 필요하며 이번 범위 밖이다.
- PR / CI 결과 표시. 세 번째 데이터 소스가 필요하다.
- Symphony 런 제어(강제 재시작, 중단, blocked 해제). 보드는 트래커 상태만 쓴다.
- WP 생성·삭제·필드 편집. 상태 전환만 지원한다.
- 기존 `/` 관측 대시보드 대체. 보드는 별도 경로로 공존한다.

## 3. 아키텍처

```
OpenProject ──(주기 fetch, 보드 전 컬럼)──▶ BoardStore ──"board:updated"──┐
                                            (GenServer)                  │
                                                                         ├─▶ BoardLive (/board)
Orchestrator ──▶ Presenter.state_payload ──"observability:dashboard"─────┘
                                                       조인 키: issue.identifier
```

기존 `/` 대시보드는 **런타임 우선**이다. 오케스트레이터가 들고 있는 항목(running/retry/blocked)만
렌더한다. 칸반은 반대로 **트래커 우선**이어야 한다. 프로젝트의 모든 WP가 먼저 깔리고 런타임 상태가
그 위에 얹힌다. 따라서 기존 payload 확장이 아니라 독립적인 두 번째 데이터 소스가 필요하다.

### 3.1 신규 구성요소

| 모듈 | 책임 |
|---|---|
| `SymphonyElixir.BoardStore` | 보드 컬럼 전체 상태의 WP를 주기 fetch. last-known-good 유지, 변경 시에만 broadcast |
| `SymphonyElixir.BoardStore.TransitionCache` | `{type_id, status_id}` → 허용 전이 목록 캐시 |
| `SymphonyElixirWeb.BoardPubSub` | 토픽 `board:updated` |
| `SymphonyElixirWeb.BoardLive` | `/board` LiveView. 두 토픽 구독 + 1초 경과시간 tick |

`BoardStore`는 `SymphonyElixir.start_runtime/0`의 children에 `Phoenix.PubSub` 뒤에 추가한다.

### 3.2 기존 코드 변경

| 파일 | 변경 |
|---|---|
| `lib/symphony_elixir/tracker.ex` | `@callback update_issue_state/2`, `@callback allowed_transitions/1` 을 `@optional_callbacks`로 추가 + 위임 함수 |
| `lib/symphony_elixir/openproject/adapter.ex` | 위 두 콜백 구현. 기존 `Client` 함수에 위임 |
| `lib/symphony_elixir/openproject/client.ex` | `fetch_allowed_transitions/1` 추가 (form 엔드포인트) |
| `lib/symphony_elixir/config/schema.ex` | `embeds_one(:board, Board)` 추가 |
| `lib/symphony_elixir_web/router.ex` | `live("/board", BoardLive, :index)` 추가 |
| `lib/symphony_elixir.ex` | supervision children에 `BoardStore` 추가 |

`update_issue_state/2`를 `Tracker` 뒤로 넣는 이유: `BoardLive`가 `OpenProject.Client`에 직접
의존하면 포크가 진행 중인 generic tracker 방향(커밋 `5eadb28`)과 어긋나고 업스트림 머지 충돌면이
늘어난다.

## 4. 데이터 모델

### 4.1 조인

조인 키는 `Tracker.Issue.identifier` (예: `WP-914`). 이 값은 워크스페이스 키와 동일하며
(`~/Desktop/worktrees/symphony/WP-914`), Presenter의 running/retry/blocked 엔트리도 같은 키를 쓴다.

```
runtime_index = Map.new(running ++ retry ++ blocked, &{&1.issue_identifier, &1})
card.runtime  = Map.get(runtime_index, card.identifier)   # nil이면 유휴
```

### 4.2 카드가 담는 것

`Tracker.Issue`에서: `identifier`, `title`, `state`, `priority`, `assignee_id`, `url`, `updated_at`.
런타임에서: 상태(running / retrying / blocked), `attempt`, `started_at`, blocked 사유.

경과시간은 서버가 계산하지 않는다. `started_at`만 넘기고 `BoardLive`의 1초 tick이 화면에서
계산한다 (`DashboardLive`의 `runtime_seconds_from_started_at/2` 패턴 재사용).

## 5. 설정

`WORKFLOW.md` front matter에 `board` 블록을 추가한다. 전부 선택 사항이다.

```yaml
board:
  enabled: true
  refresh_interval_ms: 15000
  columns:
    - New
    - Specified
    - Scheduled
    - In progress
    - Developed
    - Test failed
    - Closed
    - Rejected
```

- `columns` 기본값은 `tracker.active_states ++ tracker.terminal_states`. 위 예시처럼 명시하면
  `Specified`(active 아님) 같은 중간 상태도 보드에 포함할 수 있다.
- `refresh_interval_ms`는 `polling.interval_ms`(오케스트레이터)와 **분리한다**. 보드 조회는
  대상 상태가 더 넓어 비용이 크고, 사람이 보는 화면이라 요구 주기가 다르다. 기본 15초.
- `enabled: false`면 `BoardStore`를 띄우지 않고 `/board`는 404를 반환한다.

### 5.1 조회 범위 (assignee filter)

`BoardStore`는 `Tracker.fetch_issues_by_states/1`을 그대로 재사용한다. 따라서 `OpenProject.Client`의
기존 `assignee_filter`를 자동으로 상속하며, **보드에는 본인에게 할당된 WP만 보인다.**

이는 의도된 초기 동작이다. 프로젝트 전체를 보는 `board.scope: assignee | project` 토글은 필요해질
때 추가한다 (YAGNI).

## 6. 전이 규칙

### 6.1 진실의 출처

전이 규칙을 코드나 설정에 하드코딩하지 않는다. OpenProject의 워크플로 정의를 그대로 따른다.

```
POST /api/v3/work_packages/{id}/form
Content-Type: application/json
{}

→ _embedded.schema.status._links.allowedValues   # [{href, title}, ...]
```

이 엔드포인트는 POST이지만 **비파괴적이다**. API 문서상 "입력을 검증하고 schema 응답을 반환"하며
WP를 변경하지 않는다. 응답의 `allowedValues`는 해당 WP의 타입·현재 상태·요청자 역할에 대해
OpenProject가 허용하는 전이 집합이다.

> **구현 첫 단계에서 실제 응답 형태를 확정할 것.** 아래 명령으로 필드 경로를 검증한 뒤 파서를 쓴다.
> 본 설계는 문서 기반 추정이며 라이브 검증을 거치지 않았다.
>
> ```bash
> curl -s -u "apikey:$OPENPROJECT_API_KEY" -X POST \
>   -H 'Content-Type: application/json' -d '{}' \
>   "$OPENPROJECT_URL/api/v3/work_packages/914/form" \
>   | python3 -c 'import sys,json;print(json.dumps(json.load(sys.stdin)["_embedded"]["schema"]["status"],indent=2,ensure_ascii=False))'
> ```

### 6.2 캐싱

카드마다 form을 부르면 보드 렌더 비용이 카드 수에 비례한다. OpenProject 워크플로는 (타입, 역할)
단위로 정의되므로 **같은 타입·같은 현재 상태의 WP는 전이 집합이 동일하다.**

- 캐시 키: `{type_id, current_status_id}`
- TTL: 10분
- 웜업: lazy. 카드 렌더 시점이 아니라 **dragstart 시점**에 조회한다.

이렇게 하면 요청 수가 카드 수와 무관하게 (타입 × 상태) 조합 수로 수렴한다. 실제로는 한 자릿수다.

`Tracker.Issue`에 `type_id`가 없으므로 `native_ref`에 담아 온다. `OpenProject.Client.normalize_work_package/1`
에서 `_links.type` 의 href로부터 추출해 `native_ref["type_id"]`로 넣는다.

### 6.3 화면 제약

- `allowedValues`가 비었거나 조회에 실패하면 카드에 `draggable` 속성을 붙이지 않는다.
- dragstart 시 허용된 상태의 컬럼만 드롭 타깃으로 활성화한다. 나머지 컬럼은 dim 처리 +
  `pointer-events: none`.
- **실패 시 fail closed.** 조회 실패했다고 드래그를 열어두면 사용자가 시도했다가 422를 받고
  이유를 알 수 없다. 드래그를 막고 툴팁으로 이유를 표시한다.

### 6.4 서버측 재검증

클라이언트를 신뢰하지 않는다. `handle_event("move", ...)`에서 전이 캐시를 다시 조회해 목표 상태가
허용 집합에 있는지 확인하고, 없으면 쓰기 없이 거부한다.

## 7. 쓰기 경로

```
dragend
  → pushEvent("move", %{"identifier" => "WP-914", "to" => "Scheduled"})
    → 서버측 전이 재검증 (§6.4)             실패 → flash, 종료
    → 러닝 중 + 목표가 active 아님?          → 확인 모달 (§7.1)
    → Tracker.update_issue_state(id, state)
    → BoardStore.refresh_now()
```

`OpenProject.Client.update_issue_state/2`는 **이미 lock version 충돌 재시도를 구현하고 있다**
(커밋 `396dfee`). 새로 만들 것이 없다.

### 7.1 러닝 중 카드 이동 경고

목표 상태가 `tracker.active_states`에 없고 해당 WP에 running 엔트리가 있으면 확인 모달을 띄운다.

> 이 WP의 에이전트가 실행 중입니다. 상태를 옮기면 Symphony가 에이전트를 중단합니다.
> 워크스페이스는 유지되며, 다시 active 상태로 되돌리면 재개됩니다.

이는 SPEC의 "non-active 상태 → 에이전트 정지, 워크스페이스 유지" 동작에서 온다. 사용자가 모르고
실행 중인 작업을 죽이는 것을 막는다.

### 7.2 낙관적 UI를 쓰지 않는다

WP 상태의 쓰기 주체가 둘이다 — 사람(보드)과 에이전트(워크플로 전환). 낙관적으로 로컬 상태를
바꾸면 에이전트가 동시에 다른 전환을 했을 때 화면이 거짓말을 한다.

대신 해당 카드에만 "이동 중" 스피너를 띄우고, `refresh_now()` 결과가 도착하면 확정한다. 지연은
한 번의 왕복(수백 ms)이며 정직하다.

## 8. 갱신과 실시간성

| 소스 | 방식 | 주기 |
|---|---|---|
| OpenProject WP | `BoardStore` 폴링 | `board.refresh_interval_ms` (기본 15초) |
| Symphony 런타임 | 기존 `observability:dashboard` 구독 | 오케스트레이터가 변경 시 broadcast |
| 경과시간 | LiveView 로컬 tick | 1초 |

`BoardStore`는 fetch 결과를 이전 스냅샷과 비교해 **변경이 있을 때만** broadcast한다. 15초마다
무조건 broadcast하면 연결된 모든 LiveView가 불필요하게 재렌더된다.

쓰기 성공 직후에는 다음 틱을 기다리지 않고 `refresh_now()`로 즉시 조회한다.

OpenProject 웹훅은 이번 범위에 넣지 않는다. 폴링으로 충분하고, 웹훅은 Symphony에 인바운드
엔드포인트와 서명 검증을 추가해야 해서 공격면이 늘어난다. 나중에 필요하면 `BoardStore`에
`refresh_now()`를 부르는 컨트롤러 하나만 붙이면 되므로 이 설계를 막지 않는다.

## 9. 에러 처리

| 실패 | 동작 |
|---|---|
| `BoardStore` fetch 실패 | last-known-good 스냅샷 유지. `stale_since` 노출 → 화면 상단 stale 배너. 지수 백오프(기본 간격 기준, 상한 5분) |
| Symphony 스냅샷 타임아웃 | 런타임 배지만 `unknown`으로 표시. 보드 컬럼과 카드는 정상 동작 |
| 전이 form 조회 실패 | 해당 카드 드래그 비활성 + 툴팁 (§6.3) |
| `update_issue_state` 409 | Client가 이미 재시도. 최종 실패 시 flash + 즉시 refresh |
| `update_issue_state` 422 | flash에 OpenProject 오류 메시지 표시 + 즉시 refresh |
| `board.enabled: false` | `BoardStore` 미기동, `/board` 404 |

원칙: 어떤 실패도 `/` 관측 대시보드나 오케스트레이터 동작에 영향을 주지 않는다. `BoardStore`는
supervision tree에서 독립적으로 재시작되며 오케스트레이터와 상태를 공유하지 않는다.

## 10. UI

경로 `/board`. 기존 `/`는 그대로 둔다.

- 컬럼: `board.columns` 순서대로. 컬럼 헤더에 상태명과 카드 수.
- 카드: `identifier` · 제목 · 우선순위 · Symphony 배지 · 경과시간. `identifier` 클릭 시 `issue.url`로.
- 배지: `running`(초록, 경과시간) / `retry #N`(주황) / `blocked`(빨강, 사유) / 없음(유휴).
- 상단: stale 배너(있을 때), 마지막 갱신 시각, 연결 상태.

스타일은 기존 `priv/static/dashboard.css`를 확장한다. 별도 CSS 파일을 만들지 않는다.

드래그앤드롭은 LiveView JS 훅 하나(`BoardDrag`)로 구현한다. HTML5 drag 이벤트 +
`pushEvent`. 정적 자산이 `StaticAssetController`로 서빙되므로 훅도 같은 방식으로 추가한다.
외부 드래그 라이브러리를 넣지 않는다.

## 11. 테스트

`make all` 커버리지 게이트를 통과해야 한다.

**`BoardStore`** — 기존 `client_module()` 주입 패턴 사용
- fetch 성공 시 스냅샷 갱신 + broadcast
- fetch 결과가 이전과 동일하면 broadcast 하지 않음
- fetch 실패 시 last-known-good 유지 + `stale_since` 설정
- 연속 실패 시 백오프 증가, 상한에서 멈춤
- `refresh_now/0`가 틱과 무관하게 즉시 조회

**`TransitionCache`**
- 같은 `{type_id, status_id}` 두 번 조회 시 HTTP 요청 1회
- TTL 경과 후 재조회
- 조회 실패 시 캐시에 넣지 않음(다음에 재시도)

**`OpenProject.Client.fetch_allowed_transitions/1`**
- form 응답에서 `allowedValues` 파싱
- 필드 누락/형태 불일치 시 `{:error, _}`

**`BoardLive`** — `Phoenix.LiveViewTest`
- `board.columns` 순서대로 컬럼 렌더
- 런타임 엔트리가 있는 카드에 배지, 없는 카드에 배지 없음
- 허용되지 않은 전이로 `move` 이벤트를 보내면 쓰기 없이 거부
- 러닝 중 카드를 non-active로 이동 시 확인 모달
- stale 상태에서 배너 렌더

## 12. 라이브 검증 필요 항목

설계가 문서 기반 추정에 의존하는 지점. 구현 착수 시 실제 인스턴스(`op.cloudsec.lan`)로 확인한다.

1. `POST /work_packages/{id}/form` 응답의 status `allowedValues` 정확한 JSON 경로 (§6.1)
2. `allowedValues`가 요청자 역할까지 반영하는지 (권한 없는 전이가 빠지는지)
3. `_links.type` href에서 `type_id` 추출 형태
4. 빈 body `{}` POST가 실제로 WP를 변경하지 않는지 (`updatedAt` 불변 확인)

4번은 특히 중요하다. 만약 변경이 발생한다면 `GET /work_packages/schemas/{project_id}-{type_id}`로
대체하고, 전이 정확도가 떨어지는 대신 서버측 재검증(§6.4)과 422 처리에 더 의존한다.

## 13. 구현 순서

1. §12의 라이브 검증 (코드 없음)
2. `Client.fetch_allowed_transitions/1` + `normalize_work_package/1`에 `type_id` 추가
3. `Tracker` 콜백 2개 + `OpenProject.Adapter` 구현
4. `config/schema.ex`에 `board` 블록
5. `BoardStore` + `TransitionCache` + supervision 등록
6. `BoardPubSub` + `BoardLive` (읽기 전용, 드래그 없음) + 라우트
7. `BoardDrag` JS 훅 + 전이 제약
8. 쓰기 경로 + 확인 모달
9. 에러 상태 UI (stale 배너, unknown 배지)

6단계까지가 "모니터링" 부분이며 독립적으로 쓸 만하다. 7~8단계가 "상태 관리"다. 6단계에서 한 번
끊어 실제로 써 보고 진행할 것을 권한다.
