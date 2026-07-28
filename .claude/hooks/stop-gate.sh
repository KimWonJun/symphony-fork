#!/usr/bin/env bash
# Stop 훅: 워크트리 .claude/gate-level 을 읽어 게이트 실행. 실패 시 block 으로 재개 강제.
input=$(cat)
active=$(printf "%s" "$input" | jq -r ".stop_hook_active // false")
[ "$active" = "true" ] && exit 0   # 재진입 루프 방지: 2회차엔 그냥 통과
level=$(cat .claude/gate-level 2>/dev/null || echo skip)
[ "$level" = "skip" ] && exit 0
report=$(GATE_LEVEL="$level" AUTO_FIX=1 "$HOME/.config/symphony/verify-gate.sh" 2>/dev/null | tail -1)
result=$(printf "%s" "$report" | jq -r ".result // \"fail\"")
if [ "$result" = "pass" ]; then
  exit 0
fi
fixed=$(printf "%s" "$report" | jq -rc ".fixedFiles")
reason="검증 게이트($level) 실패. 남은 위반을 고치고 재커밋한 뒤 종료하라. 자동수정된 파일: $fixed. 리포트: $report"
jq -nc --arg r "$reason" "{decision:\"block\",reason:\$r}"
exit 0
