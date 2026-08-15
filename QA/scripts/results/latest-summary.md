# VaniScript Expanded Regression — Latest Tester Summary

- Tester result: **BLOCKED**
- Runtime suite executed by this Tester session: **No**
- Historical candidate-17 baseline: **556/556** Swift tests green (pre-existing Main evidence; not re-run here)
- New Swift tests added by this Tester: **86**
- Intended Swift corpus: **642**
- Source-confirmed product bugs: **3**
- GitHub Actions runs available for Tester head: **0**

## Confirmed bug inventory

1. Mixed deterministic-empty + translated chunks can be classified not-ready on a later pass and trigger another provider call.
2. Oversized paragraph `blockSlices` are not end-to-end safe: request slicing, plan identity, archive persistence and reassembly are inconsistent.
3. PDF/TXT export lacks a semantic translation-completeness gate and can silently export source fallback as translated output.

See `QA/scripts/S7_TESTER_BUG_REPORT.md` for deterministic reproduction details and exact test names.

## Runtime blocker

The available Tester host is Linux x86_64 (Swift 6.2.1). `Package.swift` targets macOS 14 and the application target depends on Apple/macOS-oriented packages. The branch has no `.github/workflows` and no Actions run exists to delegate the macOS execution.

## Required target-Mac run

```bash
bash QA/scripts/run_expanded_regression.sh
```

The runner now overwrites this file with the actual GREEN/RED result and saves the complete transcript plus gate statuses under a timestamped `QA/scripts/results/<UTC-run-id>/` directory.