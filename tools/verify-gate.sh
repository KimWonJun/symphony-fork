#!/usr/bin/env bash
# 공유 검증 게이트. cwd=ini-cnapp-alert 리포 루트에서 실행.
# env: GATE_LEVEL=style|unit|integration (기본 unit), AUTO_FIX=0|1 (기본 1)
set -uo pipefail
GATE_LEVEL="${GATE_LEVEL:-unit}"
AUTO_FIX="${AUTO_FIX:-1}"
GW=./gradlew
fixed_files="[]"
stages="[]"

emit() { # name status autofixed summary
  stages=$(printf '%s' "$stages" | jq -c --arg n "$1" --arg s "$2" --argjson a "$3" --arg m "$4" \
    '. += [{"name":$n,"status":$s,"autofixed":$a,"summary":$m}]')
}

run_style() {
  if $GW spotlessCheck --console=plain >/tmp/gate.style.log 2>&1; then
    emit style pass false "clean"; return 0
  fi
  if [ "$AUTO_FIX" = "1" ]; then
    $GW spotlessApply --console=plain >/tmp/gate.apply.log 2>&1 || true
    fixed_files=$(git status --porcelain | awk '{print $2}' | jq -R . | jq -sc .)
    if $GW spotlessCheck --console=plain >/tmp/gate.style2.log 2>&1; then
      emit style pass true "spotlessApply fixed"; return 0
    fi
  fi
  emit style fail false "$(tail -5 /tmp/gate.style.log | tr '\n' ' ')"; return 1
}

run_unit() {
  if CI=true $GW test --console=plain >/tmp/gate.unit.log 2>&1; then
    emit unit pass false "unit ok"; return 0
  fi
  emit unit fail false "$(grep -E 'tests completed|FAILED' /tmp/gate.unit.log | tail -3 | tr '\n' ' ')"; return 1
}

run_integration() {
  local init=/tmp/gate-tc.gradle
  cat > "$init" <<'EOF'
allprojects { tasks.withType(Test).configureEach { systemProperty "api.version", "1.43" } }
EOF
  if $GW dbIntegrationTest resourceIntegrationTest -I "$init" --console=plain >/tmp/gate.int.log 2>&1; then
    emit integration pass false "integration ok"; return 0
  fi
  emit integration fail false "$(grep -E 'tests completed|FAILED|Docker' /tmp/gate.int.log | tail -3 | tr '\n' ' ')"; return 1
}

rc=0
run_style   || rc=1
if [ "$rc" = 0 ] && { [ "$GATE_LEVEL" = unit ] || [ "$GATE_LEVEL" = integration ]; }; then
  run_unit || rc=1
fi
if [ "$rc" = 0 ] && [ "$GATE_LEVEL" = integration ]; then
  run_integration || rc=1
fi

result=$([ "$rc" = 0 ] && echo pass || echo fail)
jq -nc --arg l "$GATE_LEVEL" --arg r "$result" --argjson s "$stages" --argjson f "$fixed_files" \
  '{level:$l,result:$r,stages:$s,fixedFiles:$f}'
exit $rc
