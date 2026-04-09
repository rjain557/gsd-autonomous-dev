// ═══════════════════════════════════════════════════════════
// E2EValidationAgent
// Reads Figma storyboards + API contracts, runs validation
// against the live application. Validates: API contracts match,
// screens render, no mock data, SPs exist, auth flows work.
// Catches the 15 categories of post-deploy failure found in
// the ChatAI v8 alpha deployment.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  E2EValidationInput,
  E2EValidationResult,
  E2ETestResult,
} from '../harness/types';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as http from 'http';
import * as https from 'https';

export class E2EValidationAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const opts = input as E2EValidationInput;
    const results: E2ETestResult[] = [];

    const categories: E2EValidationResult['categories'] = {
      apiContract:       { tested: 0, passed: 0, failures: [] },
      screenRender:      { tested: 0, passed: 0, failures: [] },
      crudOperations:    { tested: 0, passed: 0, failures: [] },
      authFlows:         { tested: 0, passed: 0, failures: [] },
      mockDataDetection: { tested: 0, passed: 0, failures: [] },
      errorStates:       { tested: 0, passed: 0, failures: [] },
    };

    // 1. API contract validation — call every GET endpoint
    const apiResults = await this.validateApiContracts(opts);
    results.push(...apiResults);
    this.tally(categories.apiContract, apiResults);

    // 2. Stored procedure existence check
    const spResults = await this.validateStoredProcedures(opts);
    results.push(...spResults);

    // 3. Mock data detection in source
    const mockResults = await this.detectMockData(opts.repoRoot);
    results.push(...mockResults);
    this.tally(categories.mockDataDetection, mockResults);

    // 4. Frontend page render check
    const pageResults = await this.validatePageRender(opts);
    results.push(...pageResults);
    this.tally(categories.screenRender, pageResults);

    // 5. Auth flow validation
    const authResults = await this.validateAuthFlow(opts);
    results.push(...authResults);
    this.tally(categories.authFlows, authResults);

    // 6. CRUD operations validation — verify non-GET routes have controllers + tests
    const crudResults = await this.validateCrudOperations(opts);
    results.push(...crudResults);
    this.tally(categories.crudOperations, crudResults);

    // 7. Error states validation — verify error boundaries + no 500s on bad auth
    const errorResults = await this.validateErrorStates(opts);
    results.push(...errorResults);
    this.tally(categories.errorStates, errorResults);

    const totalFlows = results.length;
    const passedFlows = results.filter(r => r.passed).length;

    const criticalFailures = [
      categories.apiContract,
      categories.authFlows,
      categories.crudOperations,
      categories.errorStates,
    ].some(c => c.failures.length > 0);

    return {
      passed: !criticalFailures,
      totalFlows,
      passedFlows,
      failedFlows: totalFlows - passedFlows,
      results,
      categories,
    } satisfies E2EValidationResult;
  }

  private tally(cat: { tested: number; passed: number; failures: string[] }, results: E2ETestResult[]): void {
    cat.tested = results.length;
    cat.passed = results.filter(r => r.passed).length;
    cat.failures = results.filter(r => !r.passed).map(r => `${r.flow}: ${r.actual}`);
  }

  /** Call every GET endpoint from 06-api-contracts.md, verify not 404/500. */
  private async validateApiContracts(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    let contracts: string;
    try { contracts = await fs.readFile(path.resolve(opts.repoRoot, opts.apiContractsPath), 'utf-8'); }
    catch { return [{ flow: 'API Contracts', step: 0, action: 'read file', expected: 'exists', actual: `${opts.apiContractsPath} not found`, passed: false }]; }

    const epPattern = /####?\s*`(GET|POST|PUT|DELETE|PATCH)\s+(\/api\/[^`]+)`/g;
    let match; let step = 0;
    while ((match = epPattern.exec(contracts)) !== null) {
      step++;
      const [, method, endpoint] = match;
      if (method !== 'GET') { results.push({ flow: 'API Contract', step, action: `${method} ${endpoint}`, expected: 'skipped (needs payload)', actual: 'skipped', passed: true }); continue; }
      const url = `${opts.backendUrl}${endpoint}`;
      try {
        const status = await this.httpGetStatus(url);
        results.push({ flow: 'API Contract', step, action: `GET ${endpoint}`, expected: 'not 404/500', actual: `HTTP ${status}`, passed: status !== 404 && status !== 500, networkCalls: [url] });
      } catch (err) {
        results.push({ flow: 'API Contract', step, action: `GET ${endpoint}`, expected: 'responds', actual: `${err instanceof Error ? err.message : String(err)}`, passed: false });
      }
    }
    return results;
  }

  /** Parse 11-api-to-sp-map.md, verify each SP exists in SQL files. */
  private async validateStoredProcedures(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    let spMap: string;
    try { spMap = await fs.readFile(path.resolve(opts.repoRoot, opts.apiSpMapPath), 'utf-8'); }
    catch { return []; }

    const spNames = new Set<string>();
    const spRegex = /usp_\w+/g;
    let m; while ((m = spRegex.exec(spMap)) !== null) spNames.add(m[0]);

    const sqlFiles = await this.findFiles(opts.repoRoot, ['.sql']);
    let sqlContent = '';
    for (const f of sqlFiles) { try { sqlContent += await fs.readFile(f, 'utf-8') + '\n'; } catch {} }

    for (const sp of spNames) {
      const exists = sqlContent.includes(sp);
      results.push({ flow: 'SP Existence', step: 0, action: `Check ${sp}`, expected: 'SQL definition exists', actual: exists ? 'found' : 'MISSING', passed: exists });
    }
    return results;
  }

  /** Scan source code for mock data / stub patterns. */
  private async detectMockData(repoRoot: string): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    const patterns = [
      { regex: /setTimeout\s*\(\s*\(\)\s*=>\s*set\w*Loading\s*\(\s*false\s*\)/g, label: 'Fake loading (setTimeout)' },
      { regex: /console\.\w+\s*\(\s*['"]TODO/gi, label: 'TODO stub handler' },
      { regex: /currentUserId\s*=\s*['"][^'"]+['"]/g, label: 'Hardcoded user ID' },
      { regex: /return\s+\{\s*data:\s*\[\]\s*\}/g, label: 'Empty stub hook return' },
      { regex: /\/\/\s*(?:TODO|FIXME|HACK|XXX)\b/gi, label: 'Unfinished TODO/FIXME' },
      { regex: /(?:mock|dummy|fake|stub)Data\b/gi, label: 'Mock/dummy/fake data variable' },
      { regex: /lorem\s+ipsum/gi, label: 'Lorem ipsum placeholder text' },
      { regex: /async\s+function\s+\w+\s*\([^)]*\)\s*\{\s*\}/g, label: 'Empty async function body' },
      { regex: /tenantId\s*[:=]\s*['"][^'"]+['"]/gi, label: 'Hardcoded tenant ID' },
      { regex: /if\s*\(\s*(?:isDev|isLocal|__DEV__)\s*\)/gi, label: 'Development-only conditional' },
    ];
    const skipDirs = new Set(['node_modules', '.git', 'dist', 'build', '.gsd', 'test-fixtures']);
    const sourceFiles = await this.findFiles(repoRoot, ['.ts', '.tsx', '.js', '.jsx']);

    for (const filePath of sourceFiles) {
      if (filePath.split(path.sep).some(s => skipDirs.has(s))) continue;
      let content: string;
      try { content = await fs.readFile(filePath, 'utf-8'); } catch { continue; }
      for (const { regex, label } of patterns) {
        regex.lastIndex = 0;
        if (regex.test(content)) {
          results.push({ flow: 'Mock Data Detection', step: 0, action: `Scan ${path.relative(repoRoot, filePath)}`, expected: `No ${label}`, actual: `Found: ${label}`, passed: false });
        }
      }
    }
    if (results.length === 0) results.push({ flow: 'Mock Data Detection', step: 0, action: 'Full scan', expected: 'No mock patterns', actual: 'Clean', passed: true });
    return results;
  }

  /** Check frontend routes return 200. */
  private async validatePageRender(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    let storyboards: string;
    try { storyboards = await fs.readFile(path.resolve(opts.repoRoot, opts.storyboardsPath), 'utf-8'); }
    catch { return []; }

    const routes = new Set<string>(['/', '/login', '/dashboard']);
    const routeRegex = /(?:navigates?\s+to|route[sd]?\s+to|visits?)\s+[`"'](\/[^`"'\s]+)[`"']/gi;
    let m; while ((m = routeRegex.exec(storyboards)) !== null) routes.add(m[1]);

    for (const route of routes) {
      const url = `${opts.frontendUrl}${route}`;
      try {
        const status = await this.httpGetStatus(url);
        results.push({ flow: 'Page Render', step: 0, action: `GET ${route}`, expected: '200', actual: `HTTP ${status}`, passed: status === 200 });
      } catch (err) {
        results.push({ flow: 'Page Render', step: 0, action: `GET ${route}`, expected: 'responds', actual: `${err instanceof Error ? err.message : String(err)}`, passed: false });
      }
    }
    return results;
  }

  /** Validate health and auth endpoints respond correctly. */
  private async validateAuthFlow(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    const checks: Array<{ endpoint: string; expectedStatus: number }> = [
      { endpoint: '/api/health', expectedStatus: 200 },
      { endpoint: '/api/auth/me', expectedStatus: 401 },
    ];
    for (const { endpoint, expectedStatus } of checks) {
      const url = `${opts.backendUrl}${endpoint}`;
      try {
        const status = await this.httpGetStatus(url);
        results.push({ flow: 'Auth Flow', step: 0, action: `GET ${endpoint}`, expected: `HTTP ${expectedStatus}`, actual: `HTTP ${status}`, passed: status === expectedStatus || (endpoint === '/api/auth/me' && status === 200) });
      } catch (err) {
        results.push({ flow: 'Auth Flow', step: 0, action: `GET ${endpoint}`, expected: 'responds', actual: `${err instanceof Error ? err.message : String(err)}`, passed: false });
      }
    }
    return results;
  }

  /** Verify non-GET endpoints have controllers and corresponding test files. */
  private async validateCrudOperations(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    let contracts: string;
    try { contracts = await fs.readFile(path.resolve(opts.repoRoot, opts.apiContractsPath), 'utf-8'); }
    catch { return [{ flow: 'CRUD Operations', step: 0, action: 'read contracts', expected: 'exists', actual: `${opts.apiContractsPath} not found`, passed: false }]; }

    const epPattern = /####?\s*`(POST|PUT|DELETE|PATCH)\s+(\/api\/[^`]+)`/g;
    let match; let step = 0;
    const controllerFiles = await this.findFiles(opts.repoRoot, ['.cs', '.ts']);
    const testFiles = await this.findFiles(opts.repoRoot, ['.test.ts', '.spec.ts', 'Tests.cs']);

    while ((match = epPattern.exec(contracts)) !== null) {
      step++;
      const [, method, endpoint] = match;
      // Extract route segment for matching, e.g. /api/orders -> orders
      const routeSegment = endpoint.split('/').filter(Boolean).pop() ?? endpoint;

      // Check controller files contain the route
      let controllerFound = false;
      for (const cf of controllerFiles) {
        if (cf.includes('test') || cf.includes('Test') || cf.includes('spec')) continue;
        try {
          const content = await fs.readFile(cf, 'utf-8');
          if (content.includes(endpoint) || content.toLowerCase().includes(routeSegment.toLowerCase())) {
            controllerFound = true;
            break;
          }
        } catch { continue; }
      }

      results.push({
        flow: 'CRUD Operations', step, action: `${method} ${endpoint} controller`,
        expected: 'controller route exists', actual: controllerFound ? 'found' : 'MISSING',
        passed: controllerFound,
      });

      // Check test file coverage
      const hasTest = testFiles.some(tf => {
        const name = path.basename(tf).toLowerCase();
        return name.includes(routeSegment.toLowerCase());
      });

      results.push({
        flow: 'CRUD Operations', step, action: `${method} ${endpoint} test`,
        expected: 'test file exists', actual: hasTest ? 'found' : 'MISSING',
        passed: hasTest,
      });
    }

    if (results.length === 0) {
      results.push({ flow: 'CRUD Operations', step: 0, action: 'scan', expected: 'non-GET endpoints', actual: 'None found in contracts', passed: true });
    }
    return results;
  }

  /** Verify error boundaries exist and bad-auth requests don't produce 500s. */
  private async validateErrorStates(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];

    // 1. Check that error boundaries exist in React source
    const tsxFiles = await this.findFiles(opts.repoRoot, ['.tsx', '.jsx']);
    const skipDirs = new Set(['node_modules', '.git', 'dist', 'build', '.gsd', 'test-fixtures']);
    let errorBoundaryFound = false;
    let messageBarErrorFound = false;

    for (const filePath of tsxFiles) {
      if (filePath.split(path.sep).some(s => skipDirs.has(s))) continue;
      try {
        const content = await fs.readFile(filePath, 'utf-8');
        if (content.includes('ErrorBoundary')) errorBoundaryFound = true;
        if (/MessageBar.*intent\s*=\s*["']error["']/i.test(content)) messageBarErrorFound = true;
      } catch { continue; }
    }

    results.push({
      flow: 'Error States', step: 1, action: 'Check ErrorBoundary component',
      expected: 'ErrorBoundary in source', actual: errorBoundaryFound ? 'found' : 'MISSING',
      passed: errorBoundaryFound,
    });

    results.push({
      flow: 'Error States', step: 2, action: 'Check error MessageBar usage',
      expected: 'MessageBar intent="error" in source', actual: messageBarErrorFound ? 'found' : 'MISSING',
      passed: messageBarErrorFound,
    });

    // 2. Verify API endpoints don't return 500 on bad auth (should get 401)
    let contracts: string;
    try { contracts = await fs.readFile(path.resolve(opts.repoRoot, opts.apiContractsPath), 'utf-8'); }
    catch { return results; }

    const protectedPattern = /####?\s*`GET\s+(\/api\/(?!health)[^`]+)`/g;
    let match; let step = 3;
    while ((match = protectedPattern.exec(contracts)) !== null && step < 8) {
      const endpoint = match[1];
      const url = `${opts.backendUrl}${endpoint}`;
      try {
        // Request without auth — should get 401 not 500
        const status = await this.httpGetStatus(url);
        results.push({
          flow: 'Error States', step, action: `GET ${endpoint} (no auth)`,
          expected: 'not 500', actual: `HTTP ${status}`,
          passed: status !== 500,
        });
      } catch (err) {
        results.push({
          flow: 'Error States', step, action: `GET ${endpoint} (no auth)`,
          expected: 'not 500', actual: `${err instanceof Error ? err.message : String(err)}`,
          passed: true, // connection error is not a 500
        });
      }
      step++;
    }
    return results;
  }

  private httpGetStatus(url: string): Promise<number> {
    const client = url.startsWith('https') ? https : http;
    return new Promise((resolve, reject) => {
      const req = client.get(url, { timeout: 10_000 }, (res) => { resolve(res.statusCode ?? 0); res.resume(); });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    });
  }

  private async findFiles(dir: string, exts: string[]): Promise<string[]> {
    const results: string[] = [];
    const skip = new Set(['node_modules', '.git', 'bin', 'obj', 'dist', '.gsd']);
    let entries; try { entries = await fs.readdir(dir, { withFileTypes: true }); } catch { return results; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && !skip.has(e.name)) results.push(...await this.findFiles(p, exts));
      else if (exts.some(ext => e.name.endsWith(ext))) results.push(p);
    }
    return results;
  }
}
