# GSD UI Prototyping Automation — Figma Make, Stitch, and the design-quality toolchain

> Researched 2026-06-11 (official Figma docs + public GitHub). Question: can the Figma Make
> step (generate → publish → test URL) be automated end-to-end? Short answer: **generation and
> publishing cannot be automated via any official surface; everything around them can.**
> Re-check on the 30-day feature cadence — Figma is clearly moving this direction (oEmbed for
> published Makes Mar-2026, Make→MCP resources, local-codebase beta).

## 1. Figma Make automation — verdict (confirmed against official docs)

| Step | Automatable? | Surface |
|---|---|---|
| Generate Make prompts | **Yes (already automated)** | GSD `figma-prompts` milestone |
| Prompt → generate app in Make | **No — UI-only** | No REST/MCP/CLI trigger exists (confirmed absent: compare-apis, REST changelog, MCP tool list) |
| Publish to URL | **No — UI-only** | Publish button only; URL is random `three-words.figma.site` |
| Retrieve published URL | **No** (validate-only) | oEmbed `GET /v1/oembed` takes the URL as *input*; can't derive it |
| **Test the published URL** | **Yes** | Public by default → ordinary Playwright web testing (low ToS risk — it's your published content) |
| **Pull Make source into repo** | **Yes** | Make→MCP **resources** (given a Make link) + UI "Push to GitHub" |

**Do not browser-drive figma.com/Make** (Playwright/Puppeteer on the editor): Figma's AUP explicitly
prohibits programmatic access outside the REST/Plugin/MCP surfaces — risks the whole workspace, and
the WebGL canvas is selector-hostile anyway. No public repo credibly automates Make generate/publish
(searched; only prompt-text helpers exist).

## 2. The pragmatic loop — automate everything except two clicks

Human does: paste prompt into Make → click Publish → paste the `*.figma.site` URL back.
The pipeline does everything else:

1. **Phase C prep (automated):** `figma-prompts` milestone emits the Make prompt pack — now also a
   **Make kit** reference (`setup.md` + `guidelines/`, see §4) so Make output leans Fluent-shaped.
2. **Human (2 clicks):** generate in Make, Publish, drop the URL into `docs/gsd/figma-make-url.txt`
   (or the intake form).
3. **Prototype URL validation (automate — extend FigmaIntegrationAgent):** Playwright loads the
   `*.figma.site` URL: page loads, no console errors, key screens reachable, screenshot pack captured
   to `memory/observability/`, oEmbed call confirms published state. Marks the 12/12 gate evidence.
4. **Code ingestion (automate):** pull Make source via Make→MCP resources or the GitHub push, store as
   Phase C deliverables for reconcile/blueprint.
5. **Design-fidelity scoring (optional):** `uimatch`-style Figma-frame-vs-rendered screenshot diff
   (ΔE2000 + pixel) in the gate.

This is **not too much right now** — step 3 is a modest extension of the existing Playwright-equipped
E2E machinery; steps 1/4 reuse existing surfaces.

## 3. Fully headless alternative (no Figma in the loop)

If/when a project wants zero-touch UI prototyping, these have **real APIs** (Make does not):

| Tool | Loop closure | Notes |
|---|---|---|
| **Vercel v0 Platform API** | prompt → code → **live demo URL** (full loop, one API) | "headless Figma Make"; beta — API churn |
| **Anima SDK/MCP** | Figma-file-aware codegen + agent publish | REST+SSE; IBM-backed 2026 |
| **Google Stitch (official MCP)** | prompt → UI design + code into repo; we host on local IIS → Playwright | free; pairs with our `infra/` deploy scripts |

Recommendation: keep Figma Make as the **client-facing prototyping surface** (PM/design review), and
treat v0/Stitch as the **autonomous ideation lane** when no human designer is in the loop.

## 4. Should Stitch create the templates + design.md for Figma Make? — Yes, with one correction

**Yes to the workflow, but the design language source of truth must be Fluent v9, not Stitch.**

- **Stitch's role (automatable via its MCP):** rapid layout/IA exploration — generate N screen-template
  candidates per module type (list/detail/form/dashboard) as wireframe-level references. Cheap, scriptable.
- **design.md + Make kit (the steering layer for Make):** author from **our** system — the
  `/fluent-v9-mastery` skill + Figma variables → a `design.md` (Google Labs spec: YAML tokens +
  design-philosophy prose) and a **Make kit** (`setup.md`: install `@fluentui/react-components`, wrap in
  `<FluentProvider>`; `guidelines/`: per-component mappings to Fluent + tokens). Make kits are the
  official mechanism for steering Make to a library — prose-steered, so review still catches drift.
- **Why not Stitch as the source:** Stitch emits its own Material-ish aesthetic; encoding that into
  Make guidelines would fight the Fluent 2 target. Stitch supplies *structure* (layouts, flows);
  Fluent supplies *language* (tokens, components, motion).

Pipeline: Stitch (layout templates, headless) → design.md + Make kit (Fluent-derived) → Make
(human, 2 clicks) → published URL auto-tested (§2).

## 5. "What design tools make the output look professional?" — current inventory + gaps

Nothing new was downloaded for this; the repo already carries the discipline layer:

- **Installed skills (repo):** `/fluent-v9-mastery` + `/fluent-v9-design-review` (the
  "senior-Microsoft-designer, not AI-admin-panel" bar + 15-category enforcement), `/react-native-mastery`
  + review, `/react-ui-design-patterns`, `/composition-patterns`, `/web-design-guidelines`,
  `chart-design-patterns`, `data-grid-mastery`, `enterprise-form-patterns`, `live-data-patterns`.
- **Worth adding** (from Cortex research, 2026-06-06 clipping "3 Claude Code skills every designer
  should install"): **Emil Kowalski motion skill** (animations/interactions), **Impeccable**
  (typography/spacing/color QA), **Taste** (grounds output in high-quality design references —
  directly attacks the "looks AI-generated" failure mode). Evaluate via `npx skills add … --list`
  on the next 30-day skills-marketplace scan; they layer under `/fluent-v9-mastery`, never override it.
- **Validation:** `uimatch` (Design Fidelity Score in CI) as the objective backstop.

## 6. Action items

- [ ] Extend FigmaIntegrationAgent: accept a published `*.figma.site` URL → Playwright validation +
      screenshot pack + oEmbed check (Phase C gate evidence).
- [x] **Make kit authored** (2026-06-11): [`figma-make-kit/`](../figma-make-kit/README.md) —
      `setup.md`, `design.md` (YAML tokens + philosophy), `guidelines/01-05` (tokens, components,
      layout, states+a11y, forbidden anti-patterns). Derived from `/fluent-v9-mastery`. Upload these
      to Figma Make (Make kit or per-prompt attachments).
- [x] **Phase C flow updated** (vault note `memory/agents/figma-integration-agent.md`): Step 0 =
      Stitch layout templates → Step 1 = Make prompt + kit → Step 2 = human 2 clicks → Step 3 =
      validation. Stitch = structure, Fluent = language.
- [x] **Installs DONE** (owner-approved, 2026-06-11). Skills live in `.claude/skills/` +
      `.agents/skills/`: `emil-design-eng` (motion/polish), `impeccable` (run `/impeccable init`
      once per project; ~23 commands incl. polish/audit/critique/animate), `design-taste-frontend` +
      `stitch-design-taste` (anti-generic references), and the **Google Labs Stitch suite**:
      `stitch-generate-design`, `stitch-loop`, `design-md` (synthesize DESIGN.md from Stitch
      projects), `enhance-prompt` (Stitch-optimized prompts), `react-components`,
      `stitch-react-native`, `stitch-extract-*`, `stitch-manage-design-system`,
      `stitch-upload-to-stitch`, plus `taste-design`, `remotion`, `shadcn-ui`.
- [x] **Stitch MCP registered** in `.claude/settings.json` (`npx @_davideast/stitch-mcp proxy`,
      `STITCH_API_KEY` from env — same placeholder pattern as the GitHub PAT). ⚠️ Remaining owner
      step: provision a Google Cloud project with the Stitch API enabled and set `STITCH_API_KEY`
      in the environment (or use gcloud OAuth ADC). Verify with
      `npx @_davideast/stitch-mcp doctor --verbose`. Note: experimental, not Google-affiliated.
- [ ] Watch (30-day cadence): Make local-codebase beta → headless hooks; MCP write tools extending to
      Make; REST changelog for Make/Sites endpoints.
