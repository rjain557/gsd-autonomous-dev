# GSD - Final Gap Audit (All Patches Applied)

## CLOSED GAPS

| # | Issue | Fix | Status |
|---|-------|-----|--------|
| 1 | Token/rate limit exhaustion | Wait-ForQuotaReset: sleep hourly, test, up to 24h | [OK] |
| 2 | Corrupt JSON from agent | Test-JsonFile + .last-good backup restore | [OK] |
| 3 | Code compiles but logically wrong | Storyboard-aware verify traces data paths + state handling | [OK] Improved |
| 4 | Figma binary unreadable | _analysis/ deliverables from Figma Make | [OK] |
| 5 | Spec contradictions waste iterations | Invoke-SpecConsistencyCheck blocks on critical conflicts before loop | [OK] |
| 6 | SQL validation incomplete | Test-SqlFiles + sqlcmd syntax parse when available | [OK] |
| 7 | Agent boundary crossing | Test-AgentBoundaries + auto-revert | [OK] |
| 8 | CLI version changes undetected | Test-CliVersionCompat parses versions, warns on untested | [OK] |
| 9 | Disk check only in retry | Test-DiskSpace at top of every iteration in both loops | [OK] |
| 10 | Network failure | Wait-ForNetwork polls 30s for 1h | [OK] |
| 11 | Blueprint missing interface detection | Loads interface-wrapper, Initialize-ProjectInterfaces | [OK] |
| 12 | Figma Make prompts never selected | Select-BlueprintPrompt / Select-BuildPrompt wired in | [OK] |
| 13 | Convergence not multi-interface aware | Interface context injected into all 5 phase prompts | [OK] |
| 14 | gsd-assess not multi-interface | Rewritten with per-interface scanning + _analysis/ | [OK] |
| 15 | No spec consistency pre-check | Invoke-SpecConsistencyCheck (same as #5) | [OK] |
| 16 | sqlcmd flag set but never used | Test-SqlSyntaxWithSqlcmd wired into Test-SqlFiles | [OK] |

## REMAINING (requires human)

| # | Scenario | Why | Frequency |
|---|----------|-----|-----------|
| A | API key expired | Can't self-renew credentials | Rare |
| B | CLI breaking changes | Can't predict flag renames (but version check warns) | Rare |
| C | Quota exhausted > 24h | Monthly billing cap | Monthly worst case |
| D | Contradictory specs | Spec check catches them but can't resolve - human decides | Per-project |
| E | Runtime logic bugs | Storyboard verify is structural, not runtime. Full fix needs Playwright | Edge cases |

## INSTALL ORDER

```powershell
# All 7 scripts in order:
powershell -ExecutionPolicy Bypass -File install-gsd-global.ps1
powershell -ExecutionPolicy Bypass -File install-gsd-blueprint.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-partial-repo.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-resilience.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-hardening.ps1
powershell -ExecutionPolicy Bypass -File patch-gsd-figma-make.ps1
# Then the 6 final integration sub-patches:
powershell -ExecutionPolicy Bypass -File final-patch-1-spec-check.ps1
powershell -ExecutionPolicy Bypass -File final-patch-2-sql-cli.ps1
powershell -ExecutionPolicy Bypass -File final-patch-3-storyboard-verify.ps1
powershell -ExecutionPolicy Bypass -File final-patch-4-blueprint-pipeline.ps1
powershell -ExecutionPolicy Bypass -File final-patch-5-convergence-pipeline.ps1
powershell -ExecutionPolicy Bypass -File final-patch-6-assess-limitations.ps1
```
