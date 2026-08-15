#!/bin/bash
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
FAILED=()

run_gate() {
  local label="$1"
  shift
  echo ""
  echo "── $label ──"
  if "$@"; then
    PASS=$((PASS + 1))
    echo "PASS: $label"
  else
    FAIL=$((FAIL + 1))
    FAILED+=("$label")
    echo "FAIL: $label"
  fi
}

run_swift_filter() {
  local pattern="$1"
  swift test --filter "$pattern"
}

echo "== VaniScript expanded destructive regression =="
echo "Swift: $(swift --version | head -1)"
echo "Policy: collect every failure; do not stop on the first discovered bug."

run_gate "[1/16] S7 adversarial coordinator" run_swift_filter "S7AdversarialCoordinatorTests"
run_gate "[2/16] S7 adversarial validator" run_swift_filter "S7AdversarialValidatorTests"
run_gate "[3/16] S7 contract boundaries" run_swift_filter "S7ContractBoundaryTests"
run_gate "[4/16] S7 document import adversarial" run_swift_filter "S7DocumentImportAdversarialTests"
run_gate "[5/16] S7 scroll edge cases" run_swift_filter "S7ScrollEdgeCaseTests"
run_gate "[6/16] Project archive adversarial" run_swift_filter "ProjectArchiveAdversarialTests"
run_gate "[7/16] Timeline cut mapper adversarial" run_swift_filter "TimelineCutTimeMapperAdversarialTests"
run_gate "[8/16] Starter glossary integrity" run_swift_filter "StarterGlossaryAdversarialTests"
run_gate "[9/16] MCP audit/cache/confirmation adversarial" run_swift_filter "McpStoreAdversarialTests"
run_gate "[10/16] Document structured-output + engine/coordinator" run_swift_filter "DocumentCloudStructuredOutputTests|DocumentTranslationEngineTests|DocumentCoordinatorTests"
run_gate "[11/16] Document planner + budget + review/scroll" run_swift_filter "SemanticChunkPlannerTests|TranslationBudgetPlannerTests|DocumentReviewWorkflowTests|DocumentReviewScrollSyncTests"
run_gate "[12/16] Document import/export/migration/security" run_swift_filter "DocumentImportServiceTests|DOCXPackageReaderTests|DocumentExportTests|DocumentTranslationExportTests|WorkflowStoreDocumentTests|ProjectMigrationTests"
run_gate "[13/16] PDF/TXT export completeness regression guard" python3 QA/scripts/s7_export_completeness_guard.py
run_gate "[14/16] Heuristic whole-app coverage inventory" python3 QA/scripts/test_coverage_inventory.py --json /tmp/vaniscript-test-coverage-gaps.json
run_gate "[15/16] Existing manifest-driven whole-app QA" bash QA/run_all.sh
run_gate "[16/16] Full Swift suite" swift test

echo ""
echo "=== EXPANDED QA SUMMARY ==="
echo "PASS gates: $PASS"
echo "FAIL gates: $FAIL"
echo "Heuristic gap report: /tmp/vaniscript-test-coverage-gaps.json"

if [[ $FAIL -gt 0 ]]; then
  echo "Failed gates:"
  for gate in "${FAILED[@]}"; do
    echo "  - $gate"
  done
  echo "RESULT: RED (expected while adversarial tests expose open bugs)"
  exit 1
fi

echo "RESULT: GREEN"
exit 0
