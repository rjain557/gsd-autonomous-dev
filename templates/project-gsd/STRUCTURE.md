# Per-project .gsd directory structure
# Created by: gsd-init (from global engine)
#
# This gets created in each repo when you first run gsd-converge

.gsd\
+-- health\
|   +-- health-current.json
|   +-- health-history.jsonl
|   +-- requirements-matrix.json
|   +-- drift-report.md
+-- code-review\
|   +-- review-current.md
|   +-- review-history\
+-- research\
|   +-- research-findings.md
|   +-- dependency-map.json
|   +-- pattern-analysis.md
|   +-- tech-decisions.md
|   +-- figma-analysis.md
+-- generation-queue\
|   +-- queue-current.json
|   +-- completed\
+-- agent-handoff\
|   +-- current-assignment.md
|   +-- handoff-log.jsonl
+-- specs\
|   +-- figma-mapping.md      (auto-populated from design\{interface}\v##)
|   +-- sdlc-reference.md     (auto-populated from docs\)
+-- logs\
