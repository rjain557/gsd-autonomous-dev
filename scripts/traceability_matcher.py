#!/usr/bin/env python3
"""
Traceability backfill matcher - maps weak satisfied_by values to actual source files.
Searches the codebase for implementations matching each requirement's description.
"""
import json
import os
import re
import subprocess
from datetime import datetime

REPO = "D:/vscode/tech-web-chatai.v8/tech-web-chatai.v8"
OUTPUT = "D:/vscode/gsd-autonomous-dev/gsd-autonomous-dev/scripts/traceability-backfill.json"

# Load weak requirements
with open(os.path.join(REPO, ".gsd/requirements/requirements-matrix.json"), "r", encoding="utf-8") as f:
    data = json.load(f)

all_weak = []
for r in data["requirements"]:
    if r.get("status") == "satisfied":
        sb = r.get("satisfied_by") or ""
        if "src/" not in sb:
            all_weak.append(r)

# Load all source files
all_files = []
for root, dirs, files in os.walk(os.path.join(REPO, "src")):
    dirs[:] = [d for d in dirs if d not in ("obj", "bin", "node_modules", ".next")]
    for fname in files:
        if fname.endswith((".cs", ".ts", ".tsx", ".json")) and "obj" not in root and "bin" not in root:
            rel = os.path.relpath(os.path.join(root, fname), REPO).replace("\\", "/")
            all_files.append(rel)
all_files.sort()

def rg_search(pattern, file_glob=None, max_count=5):
    """Run ripgrep search and return matching files."""
    cmd = ["rg", "-n", "-l", "--max-count", str(max_count), "-i", pattern]
    if file_glob:
        cmd.extend(["--glob", file_glob])
    cmd.append("src/")
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, cwd=REPO, timeout=10)
        return [l.strip().replace("\\", "/") for l in result.stdout.strip().split("\n") if l.strip()]
    except:
        return []

def find_files_by_name(name_pattern):
    """Find files matching a name pattern."""
    matches = [f for f in all_files if re.search(name_pattern, f, re.IGNORECASE)]
    return matches[:10]

def match_requirement(req):
    """Try to find source files that satisfy a requirement."""
    rid = req["id"]
    desc = req["description"]
    interface = req.get("interface", "")
    notes = req.get("notes") or ""

    files_found = []
    evidence_parts = []
    confidence = "low"

    desc_lower = desc.lower()
    notes_lower = notes.lower()
    combined = desc_lower + " " + notes_lower

    # --- KEYWORD-BASED MAPPING RULES ---

    # ENV / VITE config
    if "vite_" in combined or (".env" in combined and interface == "frontend"):
        f = find_files_by_name(r"env\.(ts|d\.ts)$")
        f += find_files_by_name(r"src/web/src/config")
        files_found = list(set(f))
        evidence_parts.append("VITE_ env vars in config/env modules")
        confidence = "high" if files_found else "low"

    # JWT / authentication / token
    if any(k in combined for k in ["jwt", "access token", "refresh token", "token blacklist", "token lifetime"]):
        f = find_files_by_name(r"[Jj]wt|[Tt]oken")
        f = [x for x in f if "obj/" not in x]
        files_found = list(set(f))
        evidence_parts.append("JWT/token service and auth handler files")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Rate limiting
    if "rate limit" in combined:
        f = find_files_by_name(r"[Rr]ate[Ll]imit")
        files_found = list(set(f))
        evidence_parts.append("Rate limiting middleware and extensions")
        confidence = "high" if files_found else "medium"

    # Security monitoring / failed login
    if any(k in combined for k in ["security monitor", "failed login", "cross-tenant attempt"]):
        f = find_files_by_name(r"[Ss]ecurity[Mm]onitor")
        files_found = list(set(f))
        evidence_parts.append("SecurityMonitoringService/Middleware")
        confidence = "high" if files_found else "medium"

    # GDPR / erasure / consent / data portability
    if any(k in combined for k in ["gdpr", "erasure", "consent manage", "data portability", "right to erasure"]):
        f = find_files_by_name(r"[Gg]dpr|[Cc]onsent")
        files_found = list(set(f))
        evidence_parts.append("GDPR service, consent controller/service")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # CCPA
    if "ccpa" in combined:
        f = find_files_by_name(r"[Cc]cpa")
        files_found = list(set(f))
        evidence_parts.append("CCPA controller and middleware")
        confidence = "high" if files_found else "medium"

    # HIPAA
    if "hipaa" in combined:
        f = find_files_by_name(r"[Hh]ipaa")
        files_found = list(set(f))
        evidence_parts.append("HIPAA middleware, compliance service, PHI detector")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # SOC 2
    if "soc 2" in combined or "soc2" in combined:
        f = find_files_by_name(r"[Ss]oc2")
        files_found = list(set(f))
        evidence_parts.append("SOC 2 audit event service")
        confidence = "high" if files_found else "medium"

    # Compliance (general)
    if "compliance" in combined and not files_found:
        f = find_files_by_name(r"[Cc]ompliance")
        files_found = list(set(f))
        evidence_parts.append("Compliance services and middleware")
        confidence = "high" if len(files_found) >= 3 else "medium"

    # Data classification
    if "data classification" in combined or "classification" in combined:
        f = find_files_by_name(r"[Dd]ata[Cc]lassification|[Cc]lassification")
        files_found = list(set(f))
        evidence_parts.append("DataClassification middleware and policy")
        confidence = "high" if files_found else "medium"

    # Key Vault / secrets
    if any(k in combined for k in ["key vault", "keyvault", "azure key vault"]):
        f = find_files_by_name(r"[Kk]ey[Vv]ault|[Ss]ecret[Nn]ame")
        files_found = list(set(f))
        evidence_parts.append("KeyVaultService, secret management")
        confidence = "high" if files_found else "medium"

    # Data retention
    if "retention" in combined:
        f = find_files_by_name(r"[Rr]etention")
        files_found = list(set(f))
        evidence_parts.append("Retention service, background job, repository")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Soft delete
    if "soft" in combined and "delete" in combined:
        f = find_files_by_name(r"[Ss]oft[Dd]elete")
        files_found = list(set(f))
        evidence_parts.append("SoftDelete service, background service")
        confidence = "high" if files_found else "medium"

    # Multi-tenant / tenant isolation
    if any(k in combined for k in ["tenant isolation", "multi-tenant", "tenantid filter", "tenant-prefix"]):
        f = find_files_by_name(r"[Tt]enant[Ii]solat|[Mm]ulti[Tt]enan")
        files_found = list(set(f))
        evidence_parts.append("Tenant isolation middleware, validator, audit")
        confidence = "high" if len(files_found) >= 3 else "medium"

    # Council / deliberation
    if any(k in combined for k in ["council", "deliberat", "consensus", "dissent"]):
        f = find_files_by_name(r"[Cc]ouncil|[Dd]eliberat|[Cc]onsensus|[Dd]issent")
        files_found = list(set(f))
        evidence_parts.append("Council orchestration, consensus, deliberation services")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Monitoring / SLA / metrics
    if any(k in combined for k in ["monitoring sla", "p95 alert", "circuit breaker open alert", "council metric"]):
        f = find_files_by_name(r"[Mm]etric|[Ss]la[Tt]hreshold|[Cc]ouncil[Aa]lert")
        files_found = list(set(f))
        evidence_parts.append("CouncilMetricsService, monitoring, SLA thresholds")
        confidence = "high" if files_found else "medium"

    # Backup / health check
    if any(k in combined for k in ["backup", "rto", "rpo"]):
        f = find_files_by_name(r"[Bb]ackup[Hh]ealth|[Bb]lob[Bb]ackup|[Bb]ackup[Pp]olicy")
        files_found = list(set(f))
        evidence_parts.append("BackupHealthCheck, BlobBackupHealthCheck")
        confidence = "high" if files_found else "medium"

    # React / TypeScript / Vite / frontend stack
    if any(k in combined for k in ["react 18", "tanstack", "zustand", "react-hook-form"]) and not files_found:
        f = [x for x in all_files if "package.json" in x and "src/web" in x]
        f += find_files_by_name(r"(store|queryClient)\.(ts|tsx)$")
        files_found = list(set(f))
        evidence_parts.append("package.json dependencies, store files")
        confidence = "high" if files_found else "medium"

    # .NET / ASP.NET / Dapper
    if any(k in combined for k in [".net 8", "asp.net", "dapper"]) and not files_found:
        f = find_files_by_name(r"\.csproj$|[Dd]apper")
        f += ["src/Server/Technijian.Api/Program.cs"]
        files_found = list(set(f))
        evidence_parts.append(".csproj, DapperRepositoryBase, Program.cs")
        confidence = "high" if files_found else "medium"

    # Testing / xUnit / Vitest / Playwright / axe-core
    if any(k in combined for k in ["unit test", "xunit", "vitest", "playwright", "axe-core", "wcag"]):
        f = find_files_by_name(r"\.(test|spec)\.(ts|tsx|cs)$")
        f += find_files_by_name(r"a11y")
        files_found = list(set(f))
        evidence_parts.append("Test files: unit tests, a11y tests, E2E specs")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # SSE / streaming
    if any(k in combined for k in ["sse", "text/event-stream", "stream"]) and "chat" in combined:
        f = find_files_by_name(r"[Cc]hat[Ss]ervice|[Cc]hat[Cc]ontroller")
        files_found = list(set(f))
        evidence_parts.append("ChatService SSE streaming implementation")
        confidence = "high" if files_found else "medium"

    # File upload
    if any(k in combined for k in ["file upload", "multipart", "/api/files"]):
        f = find_files_by_name(r"[Ff]ile(s?)(Controller|Service|Repository)")
        files_found = list(set(f))
        evidence_parts.append("FilesController, FileService, FileRepository")
        confidence = "high" if files_found else "medium"

    # API logging
    if any(k in combined for k in ["api call logging", "log_api_calls", "api logger"]):
        f = find_files_by_name(r"[Aa]pi[Ll]ogger|[Ll]ogger")
        f = [x for x in f if "src/web" in x]
        files_found = list(set(f))
        evidence_parts.append("apiLogger modules in frontend")
        confidence = "high" if files_found else "medium"

    # Chat / threads / messages
    if any(k in combined for k in ["chat", "/api/chat"]) and not files_found:
        f = find_files_by_name(r"[Cc]hat(Controller|Service|Store|Page)")
        files_found = list(set(f))
        evidence_parts.append("Chat controller, service, frontend page/store")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Billing / subscription / payment / invoice
    if any(k in combined for k in ["billing", "subscription", "payment", "invoice", "cardpointe"]):
        f = find_files_by_name(r"[Bb]illing|[Ss]ubscript|[Pp]ayment|[Ii]nvoice|[Cc]ard[Pp]ointe")
        files_found = list(set(f))
        evidence_parts.append("Billing/subscription/payment services and controllers")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Entitlements / tenant limits
    if any(k in combined for k in ["entitlement", "tenant limit", "usage limit"]):
        f = find_files_by_name(r"[Ee]ntitlement|[Ll]imit")
        files_found = list(set(f))
        evidence_parts.append("Entitlement service, limits controller/service")
        confidence = "high" if files_found else "medium"

    # MyGPTs / custom GPT
    if any(k in combined for k in ["mygpt", "custom gpt", "custom ai"]):
        f = find_files_by_name(r"[Mm]y[Gg][Pp][Tt]")
        files_found = list(set(f))
        evidence_parts.append("MyGPTs controller, service, repository, page")
        confidence = "high" if files_found else "medium"

    # Workflow / n8n
    if any(k in combined for k in ["workflow", "n8n"]):
        f = find_files_by_name(r"[Ww]orkflow|[Nn]8[Nn]")
        files_found = list(set(f))
        evidence_parts.append("Workflow/N8N controllers, services, pages")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Vector store
    if "vector store" in combined or "vector" in combined:
        f = find_files_by_name(r"[Vv]ector[Ss]tore")
        files_found = list(set(f))
        evidence_parts.append("VectorStore service, repository, controller")
        confidence = "high" if files_found else "medium"

    # Connector / MCP
    if any(k in combined for k in ["connector", "mcp"]):
        f = find_files_by_name(r"[Cc]onnector")
        files_found = list(set(f))
        evidence_parts.append("Connector service and controller")
        confidence = "high" if files_found else "medium"

    # Agent / pairing / remote agent
    if any(k in combined for k in ["agent pair", "remote agent", "agent session"]):
        f = find_files_by_name(r"[Pp]airing|[Rr]emote[Aa]gent|[Aa]gent[Ss]ession")
        files_found = list(set(f))
        evidence_parts.append("Agent pairing/session services")
        confidence = "high" if files_found else "medium"

    # Audit / audit log
    if any(k in combined for k in ["audit log", "audit trail", "audit event"]) and not files_found:
        f = find_files_by_name(r"[Aa]udit")
        files_found = list(set(f))
        evidence_parts.append("Audit service, repository, controller, filter")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Dashboard
    if "dashboard" in combined and not files_found:
        f = find_files_by_name(r"[Dd]ashboard")
        files_found = list(set(f))
        evidence_parts.append("Dashboard service, controller, page")
        confidence = "high" if files_found else "medium"

    # User / profile / settings
    if any(k in combined for k in ["user profile", "user settings", "profile setting"]):
        f = find_files_by_name(r"[Uu]ser(Controller|Service)|[Pp]rofile[Ss]etting|[Ss]etting")
        files_found = list(set(f))
        evidence_parts.append("User service, settings page")
        confidence = "high" if files_found else "medium"

    # Projects
    if "project" in combined and not files_found:
        f = find_files_by_name(r"[Pp]roject(Controller|Service|Repository|sPage)")
        files_found = list(set(f))
        evidence_parts.append("Project controller, service, repository, page")
        confidence = "high" if files_found else "medium"

    # Tool catalog
    if "tool" in combined and "catalog" in combined:
        f = find_files_by_name(r"[Tt]ool[Cc]atalog")
        files_found = list(set(f))
        evidence_parts.append("ToolCatalog controller, service, repository")
        confidence = "high" if files_found else "medium"

    # Usage / usage tracking
    if "usage" in combined and not files_found:
        f = find_files_by_name(r"[Uu]sage")
        files_found = list(set(f))
        evidence_parts.append("Usage service, repository, controller, page")
        confidence = "high" if files_found else "medium"

    # LLM / model / provider / orchestration
    if any(k in combined for k in ["llm", "model provider", "llm orchestrat", "anthropic", "openai", "azure openai", "gemini"]):
        f = find_files_by_name(r"[Ll][Ll][Mm]|[Ll]lm[Pp]rovider|[Oo]rchestrat")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("LLM orchestration, provider factory, specific providers")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # PII / anonymization / pseudonymization
    if any(k in combined for k in ["pii", "anonymiz", "pseudonymiz", "phi detect"]):
        f = find_files_by_name(r"[Pp]ii|[Aa]nonymiz|[Pp]seudonymiz|[Pp]hi[Dd]etect")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("PII pseudonymization, anonymization, PHI detector")
        confidence = "high" if files_found else "medium"

    # Prompt security / injection
    if any(k in combined for k in ["prompt security", "prompt injection", "attack pattern"]):
        f = find_files_by_name(r"[Pp]rompt[Ss]ecurity|[Aa]ttack[Pp]attern")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("PromptSecurityService, AttackPatternCorpus")
        confidence = "high" if files_found else "medium"

    # Embedding / semantic similarity
    if any(k in combined for k in ["embedding", "semantic similar"]):
        f = find_files_by_name(r"[Ee]mbedding|[Ss]emantic[Ss]imilar")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("Embedding service, semantic similarity")
        confidence = "high" if files_found else "medium"

    # Hallucination / evaluation / win rate
    if any(k in combined for k in ["hallucination", "evaluation", "win rate", "regression test"]):
        f = find_files_by_name(r"[Hh]allucination|[Ee]valuation|[Ww]in[Rr]ate|[Rr]egression")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("Evaluation/hallucination tracking services")
        confidence = "high" if files_found else "medium"

    # Observability / tracing / OpenTelemetry
    if any(k in combined for k in ["observability", "opentelemetry", "otel", "tracing", "latency"]):
        f = find_files_by_name(r"[Oo]bservab|[Oo]tel|[Ll]atency|[Aa]ctivity[Ss]ource")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("Observability: OTEL, latency profiler, activity source")
        confidence = "high" if files_found else "medium"

    # Cost / token cost
    if any(k in combined for k in ["cost calculat", "token cost", "llm cost"]):
        f = find_files_by_name(r"[Cc]ost[Cc]alcul|[Ll]lm[Uu]sage")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("CostCalculationService, LlmUsageLogger")
        confidence = "high" if files_found else "medium"

    # MSAL / Azure AD / B2C / auth
    if any(k in combined for k in ["msal", "azure ad", "b2c"]) and not files_found:
        f = find_files_by_name(r"[Mm]sal|[Aa]zure[Aa]d|[Bb]2[Cc]")
        files_found = list(set(f))
        evidence_parts.append("MSAL config, Azure AD auth handlers, B2C policies")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Login page
    if "login" in combined and interface == "frontend" and not files_found:
        f = find_files_by_name(r"[Ll]ogin|[Ss]ign[Ii]n")
        f = [x for x in f if "src/web" in x]
        files_found = list(set(f))
        evidence_parts.append("Login/SignIn pages")
        confidence = "high" if files_found else "medium"

    # Correlation ID
    if "correlation" in combined and not files_found:
        f = find_files_by_name(r"[Cc]orrelation")
        files_found = list(set(f))
        evidence_parts.append("CorrelationIdMiddleware, CorrelationRepository")
        confidence = "high" if files_found else "medium"

    # Global exception handler
    if any(k in combined for k in ["exception handler", "global exception", "error handling"]):
        f = find_files_by_name(r"[Gg]lobal[Ee]xception|[Ee]xception[Hh]andler")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("GlobalExceptionHandler middleware")
        confidence = "high" if files_found else "medium"

    # Cache / Redis
    if any(k in combined for k in ["cache", "redis"]) and not files_found:
        f = find_files_by_name(r"[Cc]ache[Ss]ervice|[Rr]edis[Cc]ache")
        files_found = list(set(f))
        evidence_parts.append("Redis cache service, tenant cache service")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Memory
    if "memory" in combined and not files_found:
        f = find_files_by_name(r"[Mm]emory(Controller|Service|Repository|Page)")
        files_found = list(set(f))
        evidence_parts.append("Memory controller, service, repository, page")
        confidence = "high" if files_found else "medium"

    # Exam / assessment
    if any(k in combined for k in ["exam", "assessment"]) and not files_found:
        f = find_files_by_name(r"[Ee]xam")
        files_found = list(set(f))
        evidence_parts.append("Exam session controller, pages, screens")
        confidence = "high" if files_found else "medium"

    # TLS / HTTPS
    if any(k in combined for k in ["tls 1.2", "https", "ssl"]) and not files_found:
        f = find_files_by_name(r"[Tt]ls[Cc]onfiguration")
        files_found = list(set(f))
        evidence_parts.append("TLS configuration extensions")
        confidence = "high" if files_found else "medium"

    # Credential rotation
    if "credential rotation" in combined or "secret rotation" in combined:
        f = find_files_by_name(r"[Cc]redential[Rr]otation|[Ss]ecret[Rr]otation")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("Credential rotation controller, secret rotation health check")
        confidence = "high" if files_found else "medium"

    # Stale agent
    if "stale" in combined and "agent" in combined:
        f = find_files_by_name(r"[Ss]tale[Aa]gent")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("StaleAgentDetectionService")
        confidence = "high" if files_found else "medium"

    # Webhook
    if "webhook" in combined and not files_found:
        f = find_files_by_name(r"[Ww]ebhook")
        files_found = list(set(f))
        evidence_parts.append("Webhook secret validation middleware")
        confidence = "high" if files_found else "medium"

    # Grace period
    if "grace period" in combined and not files_found:
        f = find_files_by_name(r"[Gg]race[Pp]eriod")
        files_found = list(set(f))
        evidence_parts.append("GracePeriodEnforcementHostedService")
        confidence = "high" if files_found else "medium"

    # Admin
    if "admin" in combined and not files_found:
        f = find_files_by_name(r"[Aa]dmin")
        files_found = list(set(f))
        evidence_parts.append("Admin controllers, services, pages")
        confidence = "high" if len(files_found) >= 2 else "medium"

    # Assistants
    if "assistant" in combined and not files_found:
        f = find_files_by_name(r"[Aa]ssistant")
        files_found = list(set(f))
        evidence_parts.append("Assistant controller, service, repository")
        confidence = "high" if files_found else "medium"

    # Message visibility
    if "message visibility" in combined:
        f = find_files_by_name(r"[Mm]essage[Vv]isibil|[Vv]isibility[Pp]olicy")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("MessageVisibilityPolicy, models")
        confidence = "high" if files_found else "medium"

    # Agent isolation
    if "agent isolation" in combined:
        f = find_files_by_name(r"[Aa]gent[Ii]solation")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("AgentIsolationService")
        confidence = "high" if files_found else "medium"

    # Serilog / structured logging
    if any(k in combined for k in ["serilog", "structured log", "log enricher"]):
        f = find_files_by_name(r"[Ss]erilog|[Ll]og[Ee]nrich")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("Serilog configuration, log enricher extensions")
        confidence = "high" if files_found else "medium"

    # Fluent UI / design system
    if any(k in combined for k in ["fluent", "design system"]) and not files_found:
        f = find_files_by_name(r"[Ff]luent|[Dd]esign[Ss]ystem")
        files_found = list(set(f))
        evidence_parts.append("FluentWrappers design system components")
        confidence = "high" if files_found else "medium"

    # Tenant model config / BYO key
    if any(k in combined for k in ["tenant model config", "byo key", "bring your own"]):
        f = find_files_by_name(r"[Tt]enant[Mm]odel[Cc]onfig")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("TenantModelConfig controller, service, repository")
        confidence = "high" if files_found else "medium"

    # Data residency
    if "data residency" in combined:
        f = find_files_by_name(r"[Dd]ata[Rr]esidency")
        files_found = list(set(f)) if not files_found else files_found
        evidence_parts.append("DataResidencyService")
        confidence = "high" if files_found else "medium"

    # Routing / query routing
    if any(k in combined for k in ["query routing", "triage", "complexity routing"]) and not files_found:
        f = find_files_by_name(r"[Rr]outing|[Tt]riage|[Cc]lassifier")
        f = [x for x in f if "src/Server" in x]
        files_found = list(set(f))
        evidence_parts.append("Query routing service, classifiers")
        confidence = "high" if files_found else "medium"

    # Directory / directory sync
    if "directory" in combined and not files_found:
        f = find_files_by_name(r"[Dd]irectory(Controller|Service|Repository)")
        files_found = list(set(f))
        evidence_parts.append("Directory controller, service, repository")
        confidence = "high" if files_found else "medium"

    # Stored procedures
    if any(k in combined for k in ["stored procedure", "sp-only", "usp_"]):
        f = find_files_by_name(r"[Ss]p[Nn]ames|[Dd]apper[Rr]epository")
        files_found = list(set(f))
        evidence_parts.append("SpNames.cs, DapperRepositoryBase")
        confidence = "high" if files_found else "medium"

    # OpenAPI / swagger spec
    if any(k in combined for k in ["openapi", "swagger"]) and not files_found:
        hits = rg_search("UseSwagger|AddSwaggerGen|OpenApi", "*.cs")
        files_found = list(set(hits))
        evidence_parts.append("Swagger/OpenAPI configuration in Program.cs")
        confidence = "high" if files_found else "medium"

    # CI/CD / GitHub Actions
    if any(k in combined for k in ["ci/cd", "github action", "pipeline", "deployment"]) and not files_found:
        evidence_parts.append("Infrastructure/CI files (not in src/)")
        confidence = "low"

    # Stored proc / database schema
    if any(k in combined for k in ["stored proc", "database schema", "sql server", "migration"]) and not files_found:
        f = find_files_by_name(r"[Ss]p[Nn]ames|[Dd]apper")
        files_found = list(set(f))
        evidence_parts.append("SpNames.cs references stored procedures")
        confidence = "medium" if files_found else "low"

    # FALLBACK: Use ripgrep on key phrases
    if not files_found:
        # Extract technical terms from description
        terms = re.findall(r'\b(?:Controller|Service|Repository|Middleware|Handler|Provider|Store|Manager)\b', desc)
        class_names = re.findall(r'\b[A-Z][a-zA-Z]+(?:Controller|Service|Repository|Middleware)\b', desc)
        api_paths = re.findall(r'/api/\S+', desc)

        for term in (class_names + api_paths)[:3]:
            hits = rg_search(re.escape(term), "*.cs")
            if hits:
                files_found.extend(hits)
                evidence_parts.append(f"Found '{term}' via search")

        if files_found:
            confidence = "medium"

    # FALLBACK 2: keyword extraction
    if not files_found:
        keywords = re.findall(r'\b[A-Z][a-z]{3,}[A-Z]\w+\b', desc)
        for kw in keywords[:3]:
            f = find_files_by_name(re.escape(kw))
            if f:
                files_found.extend(f)
                evidence_parts.append(f"Filename match for '{kw}'")
        if files_found:
            confidence = "medium"

    # Clean up
    files_found = sorted(set(f for f in files_found if "obj/" not in f and "bin/" not in f))
    src_files = [f for f in files_found if f.startswith("src/")]
    other_files = [f for f in files_found if not f.startswith("src/")]
    files_found = (src_files + other_files)[:8]

    return {
        "id": rid,
        "description": desc[:200],
        "current_satisfied_by": req.get("satisfied_by") or "",
        "recommended_files": files_found,
        "evidence": "; ".join(evidence_parts) if evidence_parts else "No matching files found",
        "confidence": confidence if files_found else "low"
    }


# Process first 50
results = []
for i, req in enumerate(all_weak[:50]):
    print(f"Processing {i+1}/50: {req['id']}...", end=" ")
    result = match_requirement(req)
    results.append(result)
    conf = result["confidence"]
    n_files = len(result["recommended_files"])
    print(f"{conf} ({n_files} files)")

output = {
    "generated": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
    "total_backfilled": len(results),
    "stats": {
        "high_confidence": sum(1 for r in results if r["confidence"] == "high"),
        "medium_confidence": sum(1 for r in results if r["confidence"] == "medium"),
        "low_confidence": sum(1 for r in results if r["confidence"] == "low"),
    },
    "requirements": results
}

with open(OUTPUT, "w", encoding="utf-8") as f:
    json.dump(output, f, indent=2)

print(f"\nDone! Wrote {len(results)} results to {OUTPUT}")
print(f"High: {output['stats']['high_confidence']}, Medium: {output['stats']['medium_confidence']}, Low: {output['stats']['low_confidence']}")
