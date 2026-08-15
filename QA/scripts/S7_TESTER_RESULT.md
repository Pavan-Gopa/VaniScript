# S7 Tester Result — Candidate 17

```yaml
status: blocked
pass_count: 0
fail_count: 0
new_tests:
  - Tests/VaniScriptTests/S7AdversarialCoordinatorTests.swift
  - Tests/VaniScriptCoreTests/S7AdversarialValidatorTests.swift
  - Tests/VaniScriptCoreTests/S7ContractBoundaryTests.swift
  - Tests/VaniScriptTests/S7DocumentImportAdversarialTests.swift
  - Tests/VaniScriptTests/S7ScrollEdgeCaseTests.swift
  - Tests/VaniScriptCoreTests/ProjectArchiveAdversarialTests.swift
  - Tests/VaniScriptCoreTests/TimelineCutTimeMapperAdversarialTests.swift
  - Tests/VaniScriptCoreTests/StarterGlossaryAdversarialTests.swift
  - Tests/VaniScriptCoreTests/McpStoreAdversarialTests.swift
failures:
  - test_name: mixedChunkDoesNotRetranslateAfterSuccessfulCommit / automaticResumeDoesNotRepayForMixedChunk
    error_excerpt: Source inspection confirms mixed plans require non-empty stored text for deterministic source-empty blocks, so a committed chunk can be classified not-ready and repay the provider.
    suspect_file: Sources/VaniScript/Services/DocumentTranslationCoordinator.swift
  - test_name: requestBuilderHonorsBlockSlice / secondSlicePlanKeepsItsIdentity / siblingSlicesDoNotOverwriteEachOther
    error_excerpt: Source inspection confirms blockSlices do not have an end-to-end unique request/archive identity; same-block sibling plans are range-ambiguous and persistence is keyed by source block ID.
    suspect_file: Sources/VaniScript/Services/DocumentTranslationCoordinator.swift
  - test_name: s7_export_completeness_guard.py
    error_excerpt: Source inspection confirms PDF/TXT reach export using aggregate rendered text after source fallback, without a semantic translation-completeness gate before save.
    suspect_file: Sources/VaniScript/Stores/WorkflowStore.swift
blockers: Full runtime execution is unavailable in this Tester environment. GitHub Actions has no workflow on this branch and reports zero workflow runs for the Tester head. The available execution host is Linux x86_64 with Swift 6.2.1, while Package.swift targets macOS 14 and the VaniScript executable depends on Apple/macOS-oriented packages. Run bash QA/scripts/run_expanded_regression.sh on the project Mac; it now persists full evidence under QA/scripts/results/.
```

## Counts and evidence status

- Candidate-17 historical baseline from Main: **556/556** Swift tests green.
- New Tester-authored Swift tests: **86**.
- Intended Swift corpus after this expansion: **642**.
- Tests actually executed by this ChatGPT Tester session: **0** — therefore `pass_count` and `fail_count` above are runtime counts for this session, not inherited baseline counts.
- Source-confirmed product bugs prepared for deterministic runtime reproduction: **3**.
- GitHub Actions runs for the Tester head before this result: **0**.

The detailed reproductions and Coder targets are in `QA/scripts/S7_TESTER_BUG_REPORT.md`.

## Required command

```bash
bash QA/scripts/run_expanded_regression.sh
```

The runner records:

- `QA/scripts/results/<UTC-run-id>/full.log`
- `QA/scripts/results/<UTC-run-id>/gates.tsv`
- `QA/scripts/results/<UTC-run-id>/summary.md`
- `QA/scripts/results/<UTC-run-id>/coverage-gaps.json`
- refreshed `QA/scripts/results/latest-summary.md`
- refreshed `QA/scripts/results/latest-gates.tsv`
- refreshed `QA/scripts/results/latest.log`

Only a target-macOS execution may replace this `blocked` result with `bugs` (runtime failures reproduced) or `qa_green` (all assigned gates and the full suite green).