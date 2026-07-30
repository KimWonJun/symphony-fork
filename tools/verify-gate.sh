#!/usr/bin/env bash
# 공유 검증 게이트. cwd=ini-cnapp-alert 리포 루트에서 실행.
# env: GATE_LEVEL=style|unit|integration (기본 unit), AUTO_FIX=0|1 (기본 1)
set -uo pipefail
GATE_LEVEL="${GATE_LEVEL:-unit}"
AUTO_FIX="${AUTO_FIX:-1}"
GW=./gradlew
fixed_files="[]"
stages="[]"

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

emit() { # name status autofixed summary
  stages=$(printf '%s' "$stages" | jq -c --arg n "$1" --arg s "$2" --argjson a "$3" --arg m "$4" \
    '. += [{"name":$n,"status":$s,"autofixed":$a,"summary":$m}]')
}

summarize() { # logfile pattern
  local log="$1" pat="$2" hit
  hit=$(grep -iE "$pat" "$log" 2>/dev/null | head -5)
  if [ -z "$hit" ]; then
    hit=$(tail -5 "$log" 2>/dev/null)
  fi
  printf '%s' "$hit" | tr '\n' ' '
}

run_style() {
  local style_log="$WORKDIR/gate.style.log" apply_log="$WORKDIR/gate.apply.log" style2_log="$WORKDIR/gate.style2.log"
  if $GW spotlessCheck --console=plain >"$style_log" 2>&1; then
    emit style pass false "clean"; return 0
  fi
  if [ "$AUTO_FIX" = "1" ]; then
    # Snapshot the current worktree as a commit object (no side effects on the
    # index/worktree) so we can diff against "state right before spotlessApply"
    # rather than against HEAD. Diffing against HEAD alone would miss files that
    # were already dirty before this run (e.g. the caller's own in-progress edit)
    # and, symmetrically, would miss files spotlessApply reformats back to exactly
    # match HEAD (git diff --name-only against HEAD would then show nothing at all).
    local pre_commit
    pre_commit=$(git stash create 2>/dev/null)
    if [ -z "$pre_commit" ]; then
      pre_commit=$(git rev-parse HEAD)
    fi
    $GW spotlessApply --console=plain >"$apply_log" 2>&1 || true
    fixed_files=$(git diff --name-only "$pre_commit" -- . 2>/dev/null | grep -v '^$' | jq -R . | jq -sc .)
    if $GW spotlessCheck --console=plain >"$style2_log" 2>&1; then
      emit style pass true "spotlessApply fixed"; return 0
    fi
  fi
  emit style fail false "$(summarize "$style_log" 'ktlint|lint error|[0-9]+ lint')"; return 1
}

run_unit() {
  local unit_log="$WORKDIR/gate.unit.log"
  if CI=true $GW test --console=plain >"$unit_log" 2>&1; then
    emit unit pass false "unit ok"; return 0
  fi
  emit unit fail false "$(summarize "$unit_log" 'FAILED|tests completed|exception|Docker')"; return 1
}

run_integration() {
  local init="$WORKDIR/gate-tc.gradle" int_log="$WORKDIR/gate.int.log"
  cat > "$init" <<'EOF'
allprojects { tasks.withType(Test).configureEach { systemProperty "api.version", "1.43" } }
EOF
  if $GW dbIntegrationTest resourceIntegrationTest -I "$init" --console=plain >"$int_log" 2>&1; then
    emit integration pass false "integration ok"; return 0
  fi
  emit integration fail false "$(summarize "$int_log" 'FAILED|tests completed|exception|Docker')"; return 1
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
