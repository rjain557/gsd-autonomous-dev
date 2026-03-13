# Install Chain (44 scripts)

## Early Chain (#1-16)
1. install-gsd-global
2. install-gsd-blueprint
3. patch-gsd-partial-repo
4. patch-gsd-resilience
5. patch-gsd-hardening
6. patch-gsd-final-validation
7. patch-gsd-council
8. patch-gsd-figma-make (Figma Make integration, multi-interface, `_analysis/`)
9-15. final-patch-1 through final-patch-7
16. patch-gsd-supervisor

## Late Chain (#17-44)
| # | Script | Purpose |
|---|--------|---------|
| 17 | patch-false-converge-fix.ps1 | Fix false convergence exit + orphaned profile code |
| 18 | patch-gsd-parallel-execute.ps1 | Parallel Sub-Task Execution |
| 19 | patch-gsd-resilience-hardening.ps1 | Resilience Hardening |
| 20 | patch-gsd-quality-gates.ps1 | Quality Gates |
| 21 | patch-gsd-multi-model.ps1 | Multi-Model LLM Integration |
| 22 | patch-gsd-differential-review.ps1 | Diff-based code review |
| 23 | patch-gsd-pre-execute-gate.ps1 | Build before commit |
| 24 | patch-gsd-acceptance-tests.ps1 | Per-requirement acceptance tests |
| 25 | patch-gsd-api-contract-validation.ps1 | Controller vs OpenAPI spec validation |
| 26 | patch-gsd-visual-validation.ps1 | Figma screenshot diff via Playwright |
| 27 | patch-gsd-design-token-enforcement.ps1 | Hardcoded CSS value detection |
| 28 | patch-gsd-compliance-engine.ps1 | Per-iteration SEC-*/COMP-* audit + DB migration + PII |
| 29 | patch-gsd-speed-optimizations.ps1 | Research skip, smart batch, prompt dedup |
| 30 | patch-gsd-agent-intelligence.ps1 | Agent performance scoring, warm-start patterns |
| 31 | patch-gsd-loc-tracking.ps1 | LOC tracking, cost-per-line, ntfy integration |
| 32 | patch-gsd-runtime-smoke-test.ps1 | DI validation, API 500 check, FK seed order |
| 33 | patch-gsd-partitioned-code-review.ps1 | 3-way parallel code review, spec+Figma validation |
| 34 | patch-gsd-loc-cost-integration.ps1 | Running cost-per-line in ntfy, enhanced LOC |
| 35 | patch-gsd-maintenance-mode.ps1 | gsd-fix, gsd-update, --Scope, --Incremental |
| 36 | patch-gsd-council-requirements.ps1 | Council Requirements Verification |
| 37 | patch-gsd-partial-decompose.ps1 | Auto-decompose stuck partial requirements |
| 38 | patch-gsd-sequential-review.ps1 | Rate-limit-aware chunked code review v2 |
| 39 | patch-gsd-rate-limiter.ps1 | Proactive RPM enforcement |
| 40 | patch-gsd-cost-optimization.ps1 | Cost-per-line toward $0.01 |
| 41 | patch-gsd-wave-research.ps1 | Wave-based targeted research + decompose fixes |
| 42 | patch-gsd-execute-diseases.ps1 | Execute phase fixes |
| 43 | patch-gsd-convergence-diseases.ps1 | 7 disease fixes |
| 44 | patch-gsd-health-velocity.ps1 | Health Velocity Monitor |

Note: `patch-gsd-7model-optimize.ps1` exists but is NOT in the install chain (superseded).
