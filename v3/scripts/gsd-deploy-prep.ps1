<#
.SYNOPSIS
    GSD Deploy Prep - Generate deployment artifacts (Docker, CI/CD, environment configs)
.DESCRIPTION
    Generates all artifacts needed to deploy the application. Runs after compliance
    and test phases pass. Produces deployment-ready files the developer can use directly.

    Artifacts:
      - Dockerfile (backend .NET multi-stage)
      - Dockerfile.frontend (React + nginx)
      - docker-compose.yml (local dev + CI)
      - .github/workflows/ci-cd.yml (GitHub Actions)
      - appsettings.Staging.json / appsettings.Production.json templates
      - .env.example (frontend environment vars)
      - deploy-prep-report.json + deploy-prep-summary.md

    Usage:
      pwsh -File gsd-deploy-prep.ps1 -RepoRoot "D:\repos\project"
      pwsh -File gsd-deploy-prep.ps1 -RepoRoot "D:\repos\project" -CloudTarget azure
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [ValidateSet("azure","aws","gcp","generic")]
    [string]$CloudTarget = "generic",
    [int]$BackendPort  = 5000,
    [int]$FrontendPort = 3000,
    [switch]$SkipCiCd,
    [switch]$SkipDocker,
    [switch]$SkipEnvConfigs
)

$ErrorActionPreference = "Continue"

$v3Dir    = Split-Path $PSScriptRoot -Parent
$RepoRoot = (Resolve-Path $RepoRoot).Path
$GsdDir   = Join-Path $RepoRoot ".gsd"
$repoName = Split-Path $RepoRoot -Leaf

$globalLogDir = Join-Path $env:USERPROFILE ".gsd-global/logs/$repoName"
if (-not (Test-Path $globalLogDir)) { New-Item -ItemType Directory -Path $globalLogDir -Force | Out-Null }
$timestamp    = Get-Date -Format "yyyy-MM-dd_HHmmss"
$logFile      = Join-Path $globalLogDir "deploy-prep-$timestamp.log"
$outDir       = Join-Path $GsdDir "deploy-prep"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'HH:mm:ss') [$Level] $Message"
    Add-Content $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
    $color = switch ($Level) {
        "ERROR" { "Red" }; "WARN" { "Yellow" }; "OK" { "Green" }
        "SKIP"  { "DarkGray" }; "FIX" { "Magenta" }; "PHASE" { "Cyan" }
        default { "White" }
    }
    Write-Host "  $entry" -ForegroundColor $color
}

$modulesDir    = Join-Path $v3Dir "lib/modules"
$apiClientPath = Join-Path $modulesDir "api-client.ps1"
if (Test-Path $apiClientPath) { . $apiClientPath }

Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host "  GSD Deploy Prep" -ForegroundColor Cyan
Write-Host "  Repo: $repoName | Target: $CloudTarget" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Cyan

$report = @{
    generated_at    = (Get-Date -Format "o")
    repo            = $repoName
    cloud_target    = $CloudTarget
    artifacts       = @()
    warnings        = @()
    status          = "pass"
}

function Write-Artifact {
    param([string]$FilePath, [string]$Content, [string]$Label)
    $dir = Split-Path $FilePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $FilePath)) {
        $Content | Set-Content $FilePath -Encoding UTF8 -NoNewline
        $report.artifacts += $FilePath.Replace($RepoRoot,'').TrimStart('\','/')
        Write-Log "Created: $Label" "FIX"
    } else {
        Write-Log "Skipped (exists): $Label" "SKIP"
    }
}

# Discover project structure
$apiCsproj = Get-ChildItem -Path $RepoRoot -Filter "*.Api.csproj" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | Select-Object -First 1
if (-not $apiCsproj) {
    $apiCsproj = Get-ChildItem -Path $RepoRoot -Filter "*.csproj" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|test|Test)\\' } | Select-Object -First 1
}
$apiDir         = if ($apiCsproj) { Split-Path $apiCsproj.FullName -Parent } else { $RepoRoot }
$apiProjectName = if ($apiCsproj) { $apiCsproj.BaseName } else { $repoName }

$frontendPkg = Get-ChildItem -Path $RepoRoot -Filter "package.json" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' } | Select-Object -First 1
$frontendDir    = if ($frontendPkg) { Split-Path $frontendPkg.FullName -Parent } else { $null }
$frontendRelDir = if ($frontendDir) { $frontendDir.Replace($RepoRoot,'').TrimStart('\','/') } else { "frontend" }
$apiRelDir      = $apiDir.Replace($RepoRoot,'').TrimStart('\','/')

$slnFile = Get-ChildItem -Path $RepoRoot -Filter "*.sln" -File -ErrorAction SilentlyContinue | Select-Object -First 1
$slnRelPath = if ($slnFile) { $slnFile.Name } else { "$apiProjectName.sln" }

# Read existing appsettings for key names
$appSettings = @{}
$appSettingsFile = Get-ChildItem -Path $RepoRoot -Filter "appsettings.json" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } | Select-Object -First 1
if ($appSettingsFile) {
    try { $appSettings = Get-Content $appSettingsFile.FullName -Raw | ConvertFrom-Json -AsHashtable } catch { }
}

# Detect if build script is 'dev' or 'start'
$buildScript = "build"
$startScript = "start"
if ($frontendPkg) {
    $pkgContent = Get-Content $frontendPkg.FullName -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($pkgContent.scripts.dev) { $startScript = "dev" }
    if ($pkgContent.scripts.build) { $buildScript = "build" }
}

# ============================================================
# PHASE 1: DOCKER ARTIFACTS
# ============================================================

if (-not $SkipDocker) {
    Write-Log "--- Phase 1: Docker Artifacts ---" "PHASE"

    # Pre-compute values that can't use ternary inside here-strings
    $csprojFileName = if ($apiCsproj) { $apiCsproj.Name } else { "$apiProjectName.csproj" }

    # Backend Dockerfile
    $backendDockerfile = @"
# Build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY ["$apiRelDir/$csprojFileName", "$apiRelDir/"]
RUN dotnet restore "$apiRelDir/$csprojFileName"
COPY . .
WORKDIR "/src/$apiRelDir"
RUN dotnet build -c Release -o /app/build

FROM build AS publish
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

# Runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS final
WORKDIR /app
EXPOSE $BackendPort
ENV ASPNETCORE_URLS=http://+:$BackendPort
ENV ASPNETCORE_ENVIRONMENT=Production

# Security: run as non-root
RUN addgroup --system appgroup && adduser --system appuser --ingroup appgroup
USER appuser

COPY --from=publish /app/publish .
ENTRYPOINT ["dotnet", "${apiProjectName}.dll"]
"@
    Write-Artifact -FilePath (Join-Path $RepoRoot "Dockerfile") -Content $backendDockerfile -Label "Dockerfile (backend)"

    # Frontend Dockerfile (React + nginx)
    if ($frontendDir) {
        $frontendDockerfile = @"
# Build stage
FROM node:20-alpine AS build
WORKDIR /app
COPY $frontendRelDir/package*.json ./
RUN npm ci --silent
COPY $frontendRelDir/ .
RUN npm run $buildScript

# Runtime stage (nginx)
FROM nginx:alpine AS final
COPY --from=build /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
"@
        Write-Artifact -FilePath (Join-Path $RepoRoot "Dockerfile.frontend") -Content $frontendDockerfile -Label "Dockerfile.frontend"

        # nginx.conf
        $nginxConf = @"
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # API reverse proxy
    location /api/ {
        proxy_pass http://backend:$BackendPort;
        proxy_http_version 1.1;
        proxy_set_header Upgrade `$http_upgrade;
        proxy_set_header Connection keep-alive;
        proxy_set_header Host `$host;
        proxy_set_header X-Real-IP `$remote_addr;
        proxy_set_header X-Forwarded-For `$proxy_add_x_forwarded_for;
        proxy_cache_bypass `$http_upgrade;
    }

    # SPA fallback — all routes to index.html
    location / {
        try_files `$uri `$uri/ /index.html;
    }

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    add_header X-XSS-Protection "1; mode=block";
    add_header Referrer-Policy "strict-origin-when-cross-origin";

    # Cache static assets
    location ~* \.(js|css|png|jpg|ico|svg|woff2)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }
}
"@
        Write-Artifact -FilePath (Join-Path $RepoRoot "nginx.conf") -Content $nginxConf -Label "nginx.conf"
    }

    # docker-compose.yml
    $dbName = ($repoName -replace '[^a-zA-Z0-9]', '')
    $composeContent = @"
version: '3.8'

services:
  backend:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      ASPNETCORE_ENVIRONMENT: Development
      ConnectionStrings__DefaultConnection: "Data Source=db;Initial Catalog=$dbName;User ID=sa;Password=`${SA_PASSWORD};Encrypt=True;TrustServerCertificate=True"
      Jwt__Key: "`${JWT_SECRET}"
      Jwt__Issuer: "https://localhost:$BackendPort"
    ports:
      - "${BackendPort}:${BackendPort}"
    depends_on:
      db:
        condition: service_healthy
    restart: unless-stopped

  frontend:
    build:
      context: .
      dockerfile: Dockerfile.frontend
    ports:
      - "${FrontendPort}:80"
    depends_on:
      - backend
    restart: unless-stopped

  db:
    image: mcr.microsoft.com/mssql/server:2022-latest
    environment:
      ACCEPT_EULA: "Y"
      SA_PASSWORD: "`${SA_PASSWORD}"
      MSSQL_PID: Developer
    ports:
      - "1433:1433"
    volumes:
      - sqldata:/var/opt/mssql
    healthcheck:
      test: /opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P "`${SA_PASSWORD}" -Q "SELECT 1" -b
      interval: 10s
      timeout: 5s
      retries: 10
    restart: unless-stopped

volumes:
  sqldata:
"@
    Write-Artifact -FilePath (Join-Path $RepoRoot "docker-compose.yml") -Content $composeContent -Label "docker-compose.yml"

    # .env.example (never commit real secrets)
    $envExample = @"
# Copy this to .env and fill in real values (NEVER commit .env)
SA_PASSWORD=YourStrong@Passw0rd
JWT_SECRET=your-256-bit-random-secret-key-here-minimum-32-chars
ASPNETCORE_ENVIRONMENT=Development
"@
    Write-Artifact -FilePath (Join-Path $RepoRoot ".env.example") -Content $envExample -Label ".env.example"
}

# ============================================================
# PHASE 2: CI/CD PIPELINE
# ============================================================

if (-not $SkipCiCd) {
    Write-Log "--- Phase 2: CI/CD Pipeline (GitHub Actions) ---" "PHASE"

    $githubDir = Join-Path $RepoRoot ".github/workflows"
    if (-not (Test-Path $githubDir)) { New-Item -ItemType Directory -Path $githubDir -Force | Out-Null }

    $azureTarget = if ($CloudTarget -eq "azure") { @"

      # Deploy to Azure (configure secrets in GitHub → Settings → Secrets)
      - name: Azure Login
        uses: azure/login@v2
        with:
          creds: `${{ secrets.AZURE_CREDENTIALS }}

      - name: Deploy to Azure App Service
        uses: azure/webapps-deploy@v3
        with:
          app-name: `${{ secrets.AZURE_APP_NAME }}
          images: ghcr.io/`${{ github.repository }}/backend:latest
"@ } else { "      # Add your cloud deployment step here" }

    $ciCdContent = @"
name: CI/CD Pipeline

on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]

env:
  REGISTRY: ghcr.io
  BACKEND_IMAGE: ghcr.io/`${{ github.repository }}/backend
  FRONTEND_IMAGE: ghcr.io/`${{ github.repository }}/frontend

jobs:
  # ---- Backend ----
  backend-test:
    runs-on: ubuntu-latest
    services:
      mssql:
        image: mcr.microsoft.com/mssql/server:2022-latest
        env:
          ACCEPT_EULA: Y
          SA_PASSWORD: Test@12345678
        ports: ['1433:1433']
        options: --health-cmd "/opt/mssql-tools/bin/sqlcmd -S localhost -U sa -P Test@12345678 -Q 'SELECT 1'" --health-interval 10s --health-timeout 5s --health-retries 10
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Restore
        run: dotnet restore
      - name: Build
        run: dotnet build --no-restore -c Release
      - name: Test
        run: dotnet test --no-build -c Release --logger "trx;LogFileName=results.xml"
        env:
          ConnectionStrings__DefaultConnection: "Data Source=localhost;Initial Catalog=TestDb;User ID=sa;Password=Test@12345678;Encrypt=True;TrustServerCertificate=True"
      - name: Publish test results
        uses: dorny/test-reporter@v1
        if: always()
        with:
          name: .NET Tests
          path: '**/*.trx'
          reporter: dotnet-trx

  # ---- Frontend ----
  frontend-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: $frontendRelDir/package-lock.json
      - run: npm ci
        working-directory: $frontendRelDir
      - run: npm test -- --watchAll=false --ci --coverage
        working-directory: $frontendRelDir
      - run: npm run $buildScript
        working-directory: $frontendRelDir

  # ---- Security ----
  security-scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: npm audit
        run: npm audit --audit-level=high
        working-directory: $frontendRelDir
        continue-on-error: true
      - name: .NET vulnerability scan
        run: dotnet list package --vulnerable --include-transitive

  # ---- Build & Push Docker Images ----
  build-push:
    needs: [backend-test, frontend-test]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: `${{ env.REGISTRY }}
          username: `${{ github.actor }}
          password: `${{ secrets.GITHUB_TOKEN }}
      - name: Build & push backend
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile
          push: true
          tags: `${{ env.BACKEND_IMAGE }}:latest,`${{ env.BACKEND_IMAGE }}:`${{ github.sha }}
      - name: Build & push frontend
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Dockerfile.frontend
          push: true
          tags: `${{ env.FRONTEND_IMAGE }}:latest,`${{ env.FRONTEND_IMAGE }}:`${{ github.sha }}

  # ---- Deploy ----
  deploy:
    needs: build-push
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    environment: production
    steps:
      - uses: actions/checkout@v4
$azureTarget
"@
    Write-Artifact -FilePath (Join-Path $githubDir "ci-cd.yml") -Content $ciCdContent -Label ".github/workflows/ci-cd.yml"
}

# ============================================================
# PHASE 3: ENVIRONMENT CONFIGURATION TEMPLATES
# ============================================================

if (-not $SkipEnvConfigs) {
    Write-Log "--- Phase 3: Environment Configuration Templates ---" "PHASE"

    $stagingConfig = @{
        Logging        = @{ LogLevel = @{ Default = "Warning"; "Microsoft.AspNetCore" = "Warning" } }
        AllowedHosts   = "*"
        ConnectionStrings = @{ DefaultConnection = "REPLACE_WITH_STAGING_CONNECTION_STRING" }
        Jwt            = @{ Key = "REPLACE_WITH_JWT_SECRET_FROM_KEY_VAULT"; Issuer = "https://api.staging.yourcompany.com"; Audience = "https://app.staging.yourcompany.com" }
        FeatureFlags   = @{ EnableDetailedErrors = $false; RequireHttps = $true }
    }
    $stagingFile = Join-Path $apiDir "appsettings.Staging.json"
    Write-Artifact -FilePath $stagingFile -Content ($stagingConfig | ConvertTo-Json -Depth 5) -Label "appsettings.Staging.json"

    $prodConfig = @{
        Logging      = @{ LogLevel = @{ Default = "Error"; "Microsoft.AspNetCore" = "Error" } }
        AllowedHosts = "yourcompany.com;api.yourcompany.com"
        ConnectionStrings = @{ DefaultConnection = "REPLACE_WITH_PROD_CONNECTION_STRING_FROM_KEY_VAULT" }
        Jwt          = @{ Key = "REPLACE_WITH_PROD_JWT_SECRET"; Issuer = "https://api.yourcompany.com"; Audience = "https://app.yourcompany.com" }
        FeatureFlags = @{ EnableDetailedErrors = $false; RequireHttps = $true }
    }
    $prodFile = Join-Path $apiDir "appsettings.Production.json"
    Write-Artifact -FilePath $prodFile -Content ($prodConfig | ConvertTo-Json -Depth 5) -Label "appsettings.Production.json"

    # Frontend .env files
    if ($frontendDir) {
        $envDev  = "VITE_API_BASE_URL=http://localhost:$BackendPort`nVITE_APP_NAME=$repoName`nVITE_ENVIRONMENT=development"
        $envProd = "VITE_API_BASE_URL=https://api.yourcompany.com`nVITE_APP_NAME=$repoName`nVITE_ENVIRONMENT=production"
        Write-Artifact -FilePath (Join-Path $frontendDir ".env.development") -Content $envDev -Label ".env.development"
        Write-Artifact -FilePath (Join-Path $frontendDir ".env.production")  -Content $envProd -Label ".env.production"
        Write-Artifact -FilePath (Join-Path $frontendDir ".env.example")     -Content $envDev.Replace('http://localhost','https://api.yourcompany.com') -Label ".env.example (frontend)"
    }
}

# ============================================================
# VERIFY HEALTH ENDPOINT
# ============================================================

Write-Log "--- Health Endpoint Verification ---" "PHASE"
$hasHealthEndpoint = $false
foreach ($f in (Get-ChildItem -Path $RepoRoot -Filter "*.cs" -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' })) {
    $c = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($c -match '(?i)(MapHealthChecks|UseHealthChecks|HealthCheck|\/health)') { $hasHealthEndpoint = $true; break }
}
if (-not $hasHealthEndpoint) {
    $report.warnings += "No health check endpoint found. Add app.MapHealthChecks('/health') for Docker/k8s readiness probes."
    Write-Log "WARNING: No /health endpoint - required for Docker readiness probes" "WARN"
} else {
    Write-Log "Health endpoint verified" "OK"
}

# ============================================================
# REPORT
# ============================================================

$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outDir "deploy-prep-report.json") -Encoding UTF8

$md = @()
$md += "# Deploy Prep Report"
$md += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Cloud: $CloudTarget | Artifacts: $($report.artifacts.Count)"
$md += ""
$md += "## Generated Artifacts"
foreach ($a in $report.artifacts) { $md += "- ``$a``" }
if ($report.warnings.Count -gt 0) {
    $md += "`n## Warnings"
    foreach ($w in $report.warnings) { $md += "- $w" }
}
$md += "`n## Next Steps"
$md += "1. Copy ``.env.example`` to ``.env`` and fill in real values"
$md += "2. Add GitHub Secrets: ``AZURE_CREDENTIALS``, ``AZURE_APP_NAME`` (or your cloud equivalents)"
$md += "3. Replace all ``REPLACE_WITH_*`` placeholders in appsettings.Production.json"
$md += "4. Run ``docker-compose up`` to test locally before pushing"
$md += "5. Push to ``main`` branch to trigger the CI/CD pipeline"
$md -join "`n" | Set-Content (Join-Path $outDir "deploy-prep-summary.md") -Encoding UTF8

Write-Host "`n============================================" -ForegroundColor Green
Write-Host "  Deploy Prep: DONE" -ForegroundColor Green
Write-Host "  Artifacts created: $($report.artifacts.Count)" -ForegroundColor DarkGray
Write-Host "  Report: $(Join-Path $outDir 'deploy-prep-summary.md')" -ForegroundColor DarkGray
Write-Host "============================================" -ForegroundColor Green
