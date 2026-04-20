# Contributing to GSD

Thanks for helping maintain the GSD autonomous development engine. This document captures the contribution workflow. For architectural background, read [`docs/GSD-Developer-Guide.md`](docs/GSD-Developer-Guide.md) first.

## Prerequisites

Set up a workstation per [`docs/GSD-Workstation-Setup.md`](docs/GSD-Workstation-Setup.md) and [`docs/workstation.md`](docs/workstation.md). Minimum:

- Node.js 18+, npm 9+
- Python 3.10+
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Environment variables from `.env.example` (at least `ANTHROPIC_API_KEY` or an active `claude` OAuth login)

Verify with:

```bash
npm install
npm run typecheck
npm run test:v6
```

Expected: 0 TypeScript errors, 31 tests pass.

## Branching model

- `main` is the deployable branch.
- Feature branches: `feat/<short-slug>` — additive work, SemVer minor bump.
- Fix branches: `fix/<short-slug>` — bug fixes, SemVer patch bump.
- Chore branches: `chore/<short-slug>` — docs, tests, refactors with no behavior change.

Never push directly to `main`. Open a PR even for tiny fixes; the reviewer runs the full check suite.

## Before you open a PR

1. **Typecheck clean** — `npm run typecheck` returns nothing.
2. **Tests pass** — `npm run test:v6` shows all tests passing. If you add a V6 primitive, add tests to [`src/harness/v6/__tests__/v6-tests.ts`](src/harness/v6/__tests__/v6-tests.ts) using the existing lightweight harness (no Jest).
3. **CHANGELOG.md updated** — add an entry under the next unreleased version.
4. **Docs updated** — if your change affects user-visible behavior (CLI flag, agent prompt, vault note schema, SDLC phase contract), update:
   - [`docs/GSD-Developer-Guide.md`](docs/GSD-Developer-Guide.md) — narrative + Appendix A (commands) + Appendix B (artifacts) + Chapter 5 (flags) as applicable
   - [`readme.md`](readme.md) — if it's a top-level capability
   - [`AGENTS.md`](AGENTS.md) — if it changes an agent's role
   - Relevant vault note in `memory/agents/*.md`

## V6 engineering rules (from CLAUDE.md)

1. Read the relevant `memory/agents/*.md` note before modifying any agent.
2. Agent system prompts live in the vault — edit there, not in code.
3. Never hardcode thresholds, configs, or deploy targets in code — they live in `memory/knowledge/`.
4. Before adding a new agent: design its vault note first, then build the class.
5. The orchestrator must log a Decision for every routing choice it makes.
6. DeployAgent MUST NOT execute unless `GateResult.passed === true` (runtime assertion).
7. Rollback logic must exist before deploy logic — never implement deploy without rollback.
8. All vault log writes use `append()` — never overwrite session/decision files.

## Version bump

This project follows [SemVer](https://semver.org/):

- **Major** (`X.0.0`) — breaking change to CLI, state schema, or agent contract. Not done casually.
- **Minor** (`6.X.0`) — additive feature (new CLI command, new agent, new primitive). Current: 6.1.0.
- **Patch** (`6.1.X`) — bug fix with no API change.

Bump all three together when you release:

- `package.json` → `"version": "X.Y.Z"`
- `VERSION` → `version=X.Y.Z`
- Add a `## [X.Y.Z] — YYYY-MM-DD` entry to [`CHANGELOG.md`](CHANGELOG.md)
- Add a row to the Document History table in [`docs/GSD-Developer-Guide.md`](docs/GSD-Developer-Guide.md)

## Writing a new test

V6 tests use a minimal harness (no Jest, no Vitest — just `ts-node` + `assert`). Add a new `test(name, fn)` call in [`src/harness/v6/__tests__/v6-tests.ts`](src/harness/v6/__tests__/v6-tests.ts). The test runs via `npm run test:v6`.

For tests that need fixtures, put them under `test-fixtures/<category>/` and reference via relative path.

## Writing a new agent

1. Draft the vault note at `memory/agents/<agent-name>.md` with frontmatter (`agent_id`, `tools`, `reads`, `writes`, `max_retries`, `timeout_seconds`).
2. Create the TypeScript class at `src/agents/<agent-name>.ts` extending `BaseAgent`. Implement only the `run()` method.
3. Register in the relevant orchestrator (`src/harness/orchestrator.ts` for pipeline agents, `src/harness/sdlc-orchestrator.ts` for SDLC agents, or `src/harness/v6/milestone-orchestrator.ts` for cross-cutting V6 agents).
4. Add the `AgentId` literal to [`src/harness/types.ts`](src/harness/types.ts).
5. Update [`AGENTS.md`](AGENTS.md) with the new agent's role and vault note reference.

## Questions

Open an issue or check the Developer Guide. The Developer Guide's Chapter 12 ("Documentation Map") lists every canonical reference.
