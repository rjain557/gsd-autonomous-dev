# GSD Front-End & Stack Intelligence — 2026 refresh

> Latest in the Technijian stack — **Fluent UI React v9, .NET 8/9 (→10), SQL Server 2025, Figma Make,
> React Native + Expo** — with what's new, what to adopt, and high-quality public repos to study.
> Researched 2026-06-11 from official docs/release notes + GitHub; Cortex front-end clippings folded in.
> Re-verify on the 30-day feature check (`memory/knowledge/feature-check-schedule.md`).

## TL;DR — the 4 moves that matter this year

1. **Plan the .NET 10 LTS migration.** .NET 8 (LTS) **and** .NET 9 (STS) **both reach end-of-support Nov 10, 2026.** .NET 10 LTS shipped Nov 11 2025 (supported to Nov 2028). Allow `net10.0` in `docs/gsd/stack-overrides.md`.
2. **Adopt SQL Server 2025 GA features:** native `JSON` type, `REGEXP_*`, Optimized Locking, and (GA) `VECTOR` + `AI_GENERATE_EMBEDDINGS`. All transparent through Dapper/SPs.
3. **Fix the Fluent↔Figma handoff:** Figma **Make** generates React+**Tailwind**, not Fluent — use it for prototype validation only. Wire **Figma Dev Mode MCP + Code Connect** so AI codegen emits `@fluentui/react-components` + `tokens.*`.
4. **Mobile = Expo SDK 56 / RN 0.85, New Architecture ON.** Reanimated v4, FlashList v2, Expo Router v6, Expo UI (SwiftUI/Compose). Share tokens+types+data with web — never UI components.

---

## 1. Microsoft Fluent UI React v9 (`@fluentui/react-components`)

- **Latest:** rolling v9 line, **v9.73.8 (~Apr 2026)**. **No v10 exists or is planned** — v9 is the converged, strategic target; Microsoft adds components onto it. Direction beyond v9 is **Fluent UI Web Components** (framework-agnostic) — a *watch item* for a React shop, no action.
- **New & useful:**
  - **`react-motion`** is first-class — motion params are direct props on motion slots. Use it for the **Optimistic / state-transition** polish the five-states rule mandates, instead of ad-hoc CSS transitions.
  - **`use*Base_unstable` hooks** (Toolbar, MessageBar, TeachingPopover, …) — the sanctioned escape hatch to build custom-composed variants without forking or boolean-prop proliferation.
  - Griffel (`makeStyles` + `tokens.*`) unchanged — existing CLAUDE.md import/token conventions stay correct.
- **Adopt:** pin a known-good minor, bump on cadence (no migration cliff). Use `react-motion` props for polish; `*Base_unstable` for deep customization.
- **Repos:** [microsoft/fluentui](https://github.com/microsoft/fluentui) (canonical stories under `packages/react-components/*/stories`) · [dmytrokirpa/fluentui-vite-react-ts](https://github.com/dmytrokirpa/fluentui-vite-react-ts) (modern Vite+TS starter) · [AndyDiep93/fluentui-app-v8-v9](https://github.com/AndyDiep93/fluentui-app-v8-v9) (v8→v9 migration ref).
- Aligns with skills: `/fluent-v9-mastery`, `/fluent-v9-design-review`.

## 2. .NET 8 / 9 / 10 (React-backed Web APIs)

- **Support cliff:** **.NET 8 (LTS) and .NET 9 (STS) BOTH EOL Nov 10, 2026.** **.NET 10 (LTS) + C# 14** shipped **Nov 11, 2025**, supported to **Nov 2028**.
- **Built-in OpenAPI** (`Microsoft.AspNetCore.OpenApi`) **replaced Swashbuckle** in templates as of .NET 9 — runtime/build-time, document transformers, **Native AOT-compatible** (Swashbuckle/NSwag are not). .NET 10 emits **OpenAPI 3.1** (+ YAML, + XML-doc→descriptions via source generator).
- Minimal APIs lower allocation/AOT-friendly; ASP.NET Core 10 adds auth metrics + **WebAuthn passkeys** in Identity.
- **Dapper + SQL Server SP-only rule stays correct** — SQL Server 2025 features below are consumed transparently as T-SQL.
- **Adopt:** schedule **.NET 10 LTS** (both current targets die in 2026); allow `net10.0` in stack-overrides. **Drop Swashbuckle for built-in OpenAPI** (enables AOT; XML-doc-driven specs feed the React client/Swagger codegen). If you codegen the React client from the OpenAPI doc, **verify your generator handles OpenAPI 3.1** before .NET 10 (3.0→3.1 nullable representation changed).
- **Repos:** [dotnet/eShop](https://github.com/dotnet/eShop) (reference API + auth + OpenAPI + Aspire) · [jasontaylordev/CleanArchitecture](https://github.com/jasontaylordev/CleanArchitecture) (Aspire + React/Angular/API options) · [ardalis/CleanArchitecture](https://github.com/ardalis/CleanArchitecture) · [stphnwlsh/CleanMinimalApi](https://github.com/stphnwlsh/CleanMinimalApi).

## 3. MS SQL Server 2025

- **GA Nov 18, 2025**, engine **v17.x** (CU1 Jan 15 2026). Free **Standard/Enterprise Developer** editions for non-prod. **Web edition + DQS/MDS/Synapse Link discontinued.**
- **GA, app-relevant (all transparent through Dapper/SPs):**
  - **Native `JSON` data type** — binary-stored, with `JSON_OBJECTAGG`/`JSON_ARRAYAGG`. ⚠️ **This gives the "no `NVARCHAR(MAX)`" rule a sanctioned alternative** for JSON payloads.
  - **`REGEXP_*`** (`REGEXP_LIKE/REPLACE/SUBSTR/…`, `SPLIT_TO_TABLE`) — in-DB validation/extraction; fits the SP-only pattern (email/phone/format checks).
  - **`VECTOR` type + `VECTOR_DISTANCE`/`_NORM`/…** and **`AI_GENERATE_EMBEDDINGS` / `CREATE EXTERNAL MODEL`** — store/query embeddings in T-SQL (keeps PHI in-DB vs a middle tier; vet the external-model endpoint for data residency under HIPAA/PCI).
  - **Optimized Locking** — less blocking/lock-memory; low-risk win for multi-tenant write paths, no code change.
  - Misc: `||` concat, `CURRENT_DATE`, `BASE64_ENCODE/DECODE`, ZSTD backup compression.
- **Preview (keep out of prod, gated by `PREVIEW_FEATURES`):** `VECTOR_SEARCH`/DiskANN vector index, Change Event Streaming, fuzzy `EDIT_DISTANCE`/`JARO_WINKLER`.
- **Data API Builder + SQL MCP server** — auto REST/GraphQL + an MCP server for agents over the DB; treat as a read-only/agent option, **not** a replacement for the Dapper+SP write path.
- **Repos:** [microsoft/sql-server-samples](https://github.com/microsoft/sql-server-samples) (AI/vector subfolders) · [Azure/data-api-builder](https://github.com/Azure/data-api-builder) · [DapperLib/Dapper](https://github.com/DapperLib/Dapper) (confirm `VECTOR`/`JSON` type handlers).

## 4. Figma Make + Dev Mode MCP (design → code)

- **Figma Make** (GA Jul 24 2025) is **prompt-to-app**, generating **React + Tailwind** (code in `App.tsx`), with design-library import + Supabase. **May 28 2026 (limited beta):** connect Make to a local codebase, element-scoped editing, **commit + open a PR** without a terminal. Publishing still beta.
- **Can we tell Make to use Fluent v9? Yes — via "Make kits", with caveats.** Make's default is
  React+Tailwind, but Figma supports steering it to a specific React component library:
  - **Make kit** = point Make at an npm design-system package + write instructions. Author a
    `setup.md` (install `@fluentui/react-components`, import its CSS, wrap the root in
    `<FluentProvider theme={webLightTheme}>`) and a granular `guidelines/` folder mapping common
    screens/components to Fluent v9 components + tokens. `@fluentui/react-components` is public npm,
    so no registry admin step. Make kits are **React-only** (Fluent v9 qualifies).
  - **Reliability:** this is LLM steering via prose, **not a hard pin** — Figma publishes no fidelity
    guarantee and Make can drift back to Tailwind for components your guidelines don't cover. Keep
    guidelines tight/granular and **run output through `/fluent-v9-design-review`** to catch drift.
  - The May-2026 local-codebase beta detects your stack and edits real code, but Figma's docs **do
    not promise it reuses your existing Fluent components** — pair it with a repo-scoped Make kit.
  - Sources: [Make kits](https://help.figma.com/hc/en-us/articles/35946832653975-Use-your-design-system-package-in-Make-kits) · [Make guidelines](https://help.figma.com/hc/en-us/articles/33665861260823-Add-guidelines-to-Figma-Make).
- **Higher fidelity = Dev Mode MCP + Code Connect (preferred for production):** map each Fluent v9
  component via Code Connect + add MCP custom rules ("replace Tailwind with our design-system tokens;
  always use our components") → AI emits **true Fluent imports/props**, deterministically, vs Make's
  steered approximation. **Recommendation: Make kit for prototype validation (Phase C); Dev Mode MCP +
  Code Connect for production codegen.**
- **The production handoff is the Dev Mode MCP server + Code Connect:**
  - **Dev Mode MCP server** (beta, Dev/Full seats) exposes design context to IDE agents (Claude Code, Cursor, Copilot): **code generation, image extraction, variable/token definitions**.
  - **Code Connect** maps Figma components → your codebase files, so the MCP server returns **exact `@fluentui/react-components` imports + your `tokens.*` syntax** instead of generic Tailwind divs.
  - **Action:** author Code Connect mappings for the Fluent v9 component library so AI codegen lands on-stack. One set of Figma variables → Fluent `tokens` (web) and the RN token module (mobile).
- Setup: [figma/mcp-server-guide](https://github.com/figma/mcp-server-guide) · [Claude Code + Figma MCP](https://help.figma.com/hc/en-us/articles/39888612464151-Claude-Code-and-Figma-Set-up-the-MCP-server).

## 5. React Native + Expo (iOS + Android)

- **Expo SDK 56** (May 21 2026): **RN 0.85, React 19.2, TS 6.0.3**. 3 SDKs/yr.
- **New Architecture (Fabric + TurboModules) is mandatory** — SDK 54 was the last to allow disabling it.
- **Reanimated v4** — New-Arch only; **worklets moved to a standalone `react-native-worklets` package** (add it when migrating v3→v4).
- **FlashList v2** — rewrite; **`estimatedItemSize` no longer required** (remove it). **Expo Router v6** — now **forks React Navigation** (don't import `@react-navigation/*` directly). **Hermes v1** default. **Expo UI stable** — native **SwiftUI (iOS) / Jetpack Compose (Android)** components: the strongest "don't look like a WebView" lever.
- **Platform raises (SDK 56):** min iOS 16.4, Xcode 26.4, Android 16 target with **edge-to-edge forced on**; iOS 26 Liquid Glass supported.
- **Adopt:** SDK 56 / RN 0.85, New Arch ON; pin Expo Router v6 + Reanimated v4 (+worklets) + FlashList v2 + expo-haptics; evaluate **Expo UI** for native-feel screens. Native-feel checklist (matches `/react-native-mastery`): safe-area/edge-to-edge insets, iOS large titles / Android edge-to-edge, FlashList for all long lists, five-states incl. **offline**.
- **Cross-platform:** **no shared UI layer** between Fluent v9 (DOM) and RN — do not share components. **Share the layer below:** design **tokens**, TypeScript **API types / Zod schemas**, **TanStack Query** data hooks, validation — over the **same .NET 8/9/10 + SQL Server + Swagger backend**. Bridge design→both via Figma Dev Mode MCP + Code Connect.
- **Repos:** [infinitered/ignite](https://github.com/infinitered/ignite) (battle-tested boilerplate) · [obytes/react-native-template-obytes](https://github.com/obytes/react-native-template-obytes) (most production-grade free starter — Router, multi-env, TanStack+Zod, MMKV, CI) · [toyamarodrigo/expo-router-template](https://github.com/toyamarodrigo/expo-router-template) (modern standard stack wired together) · official `npx create-expo-app --example with-router`.

## 6. Cortex front-end signal + a gap to close

Cortex `Inbox/` holds ~73 front-end clippings (Fluent 2 design system, Google `design.md` token spec, Figma→Claude handoff, Expo + Callstack **Apex** RN model, "3 designer skills: motion/typography/taste"). **But Cortex has no Technijian-specific front-end conventions and no record of the front-end repos** (`tech-web-myjian`, `tech-web-chatai`, `tech-web-myeos`, `tech-web-shared`, `taly-hud`). **Recommendation:** document the shared design system, approved component library (Fluent v9), token source (Figma variables), accessibility bar, and CI gates in the GSD vault (e.g. a `03-Patterns/frontend-conventions` note) so future runs inherit them.

## 7. Net actions

- [ ] Allow `net10.0` in `docs/gsd/stack-overrides.md`; schedule the .NET 10 LTS migration; verify OpenAPI 3.1 client codegen; drop Swashbuckle → built-in OpenAPI.
- [ ] Update T-SQL conventions: native `JSON` type is now allowed for JSON payloads (supersedes `NVARCHAR(MAX)` JSON); adopt `REGEXP_*` + Optimized Locking; keep vector-search/CES behind the preview flag.
- [ ] Author **Figma Code Connect** mappings for the Fluent v9 library; wire the Dev Mode MCP server for design→code.
- [ ] Standardize mobile on Expo SDK 56 + New Arch; update `/react-native-mastery` references (Reanimated v4 worklets, FlashList v2, Expo Router v6, Expo UI).
- [ ] Capture Technijian front-end conventions in the GSD vault (Cortex gap).
