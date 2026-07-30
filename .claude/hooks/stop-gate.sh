#!/usr/bin/env bash
# Stop 훅: 워크트리 .claude/gate-level 을 읽어 게이트 실행. 실패 시 block 으로 재개 강제.
input=$(cat)
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
[ "$active" = "true" ] && exit 0   # 재진입 루프 방지: 2회차엔 그냥 통과

level_path="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/gate-level"
GATE="$HOME/.config/symphony/verify-gate.sh"

# 도구/게이트 부재 시 fail-closed (jq 없이 정적 JSON)
if ! command -v jq >/dev/null 2>&1 || [ ! -x "$GATE" ]; then
  printf '%s\n' '{"decision":"block","reason":"stop-gate: 게이트 검증 불가(jq 또는 verify-gate.sh 없음) - 수동 확인 필요"}'
  exit 0
fi

level=$(cat "$level_path" 2>/dev/null || echo skip)
[ "$level" = "skip" ] && exit 0

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || true

report=$(GATE_LEVEL="$level" AUTO_FIX=1 "$GATE" 2>/dev/null | tail -1)
result=$(printf '%s' "$report" | jq -r '.result // "fail"')
fixed=$(printf '%s' "$report" | jq -rc '.fixedFiles // "[]"')
if [ "$result" = "pass" ] && [ "$fixed" = "[]" ]; then
  exit 0
fi
if [ "$result" = "pass" ]; then
  # 자동수정이 working tree만 바꾸고 커밋 안 됨 -> 커밋 유도
  reason="검증 게이트($level): spotlessApply가 파일을 자동수정했으나 커밋되지 않았다. 자동수정된 파일($fixed)을 git add & commit 한 뒤 종료하라."
else
  reason="검증 게이트($level) 실패. 남은 위반을 고치고 재커밋한 뒤 종료하라. 자동수정된 파일: $fixed. 리포트: $report"
fi
jq -nc --arg r "$reason" '{decision:"block",reason:$r}' || printf '%s\n' '{"decision":"block","reason":"stop-gate: 게이트 실패이나 reason 직렬화 실패 - 수동 확인 필요"}'
exit 0
