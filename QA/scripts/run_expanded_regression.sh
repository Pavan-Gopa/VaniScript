#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "== VaniScript expanded regression =="
echo "Swift: $(swift --version | head -1)"

echo "\n[1/12] S7 adversarial coordinator"
swift test --filter S7AdversarialCoordinatorTests

echo "\n[2/12] S7 adversarial validator"
swift test --filter S7AdversarialValidatorTests

echo "\n[3/12] S7 contract boundaries"
swift test --filter S7ContractBoundaryTests

echo "\n[4/12] S7 document import adversarial"
swift test --filter S7DocumentImportAdversarialTests

echo "\n[5/12] S7 scroll edge cases"
swift test --filter S7ScrollEdgeCaseTests

echo "\n[6/12] Project archive adversarial"
swift test --filter ProjectArchiveAdversarialTests

echo "\n[7/12] Document structured-output + engine/coordinator"
swift test --filter 'DocumentCloudStructuredOutputTests|DocumentTranslationEngineTests|DocumentCoordinatorTests'

echo "\n[8/12] Document planner + budget + review/scroll"
swift test --filter 'SemanticChunkPlannerTests|TranslationBudgetPlannerTests|DocumentReviewWorkflowTests|DocumentReviewScrollSyncTests'

echo "\n[9/12] Document import/export/migration/security"
swift test --filter 'DocumentImportServiceTests|DOCXPackageReaderTests|DocumentExportTests|DocumentTranslationExportTests|WorkflowStoreDocumentTests|ProjectMigrationTests'

echo "\n[10/12] PDF/TXT export completeness regression guard"
python3 QA/scripts/s7_export_completeness_guard.py

echo "\n[11/12] Heuristic whole-app coverage inventory"
python3 QA/scripts/test_coverage_inventory.py --json /tmp/vaniscript-test-coverage-gaps.json

echo "\n[12/12] Full Swift suite"
swift test

echo "\nExpanded regression complete."
echo "Heuristic gap report: /tmp/vaniscript-test-coverage-gaps.json"
