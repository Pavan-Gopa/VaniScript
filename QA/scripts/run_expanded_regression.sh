#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

echo "== VaniScript expanded regression =="
echo "Swift: $(swift --version | head -1)"

echo "\n[1/8] S7 adversarial coordinator"
swift test --filter S7AdversarialCoordinatorTests

echo "\n[2/8] S7 adversarial validator"
swift test --filter S7AdversarialValidatorTests

echo "\n[3/8] S7 contract boundaries"
swift test --filter S7ContractBoundaryTests

echo "\n[4/8] Document structured-output + engine/coordinator"
swift test --filter 'DocumentCloudStructuredOutputTests|DocumentTranslationEngineTests|DocumentCoordinatorTests'

echo "\n[5/8] Document planner + budget + review/scroll"
swift test --filter 'SemanticChunkPlannerTests|TranslationBudgetPlannerTests|DocumentReviewWorkflowTests|DocumentReviewScrollSyncTests'

echo "\n[6/8] Document import/export/migration/security"
swift test --filter 'DocumentImportServiceTests|DOCXPackageReaderTests|DocumentExportTests|DocumentTranslationExportTests|WorkflowStoreDocumentTests|ProjectMigrationTests'

echo "\n[7/8] Heuristic whole-app coverage inventory"
python3 QA/scripts/test_coverage_inventory.py --json /tmp/vaniscript-test-coverage-gaps.json

echo "\n[8/8] Full Swift suite"
swift test

echo "\nExpanded regression complete."
echo "Heuristic gap report: /tmp/vaniscript-test-coverage-gaps.json"
