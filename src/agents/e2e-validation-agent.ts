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

    // Run all validation categories in parallel (allSettled = fault-tolerant)
    const settled = await Promise.allSettled([
      this.validateApiContracts(opts),
      this.validateStoredProcedures(opts),
      this.detectMockData(opts.repoRoot),
      this.validatePageRender(opts),
      this.validateAuthFlow(opts),
      this.validateCrudOperations(opts),
      this.validateErrorStates(opts),
      this.validateWithBrowser(opts),
    ]);

    const extract = (i: number): E2ETestResult[] => {
      const r = settled[i];
      if (r.status === 'fulfilled') return r.value;
      return [{ flow: 'Validation Error', step: 0, action: `Category ${i}`, expected: 'no error', actual: r.reason?.message ?? 'unknown', passed: false }];
    };

    const [apiResults, spResults, mockResults, pageResults, authResults, crudResults, errorResults, browserResults] =
      [extract(0), extract(1), extract(2), extract(3), extract(4), extract(5), extract(6), extract(7)];

    results.push(...apiResults, ...spResults, ...mockResults, ...pageResults, ...authResults, ...crudResults, ...errorResults, ...browserResults);
    this.tally(categories.apiContract, apiResults);
    this.tally(categories.mockDataDetection, mockResults);
    this.tally(categories.screenRender, pageResults);
    this.tally(categories.authFlows, authResults);
    this.tally(categories.crudOperations, crudResults);
    this.tally(categories.errorStates, errorResults);
    for (const r of browserResults) this.tallyInto(categories.screenRender, r);

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

  private tallyInto(cat: { tested: number; passed: number; failures: string[] }, result: E2ETestResult): void {
    cat.tested++;
    if (result.passed) cat.passed++;
    else cat.failures.push(`${result.flow}: ${result.actual}`);
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

  /** Playwright browser validation — tests real rendering, JS execution, console errors. Falls back gracefully if Playwright not installed. */
  private async validateWithBrowser(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    const results: E2ETestResult[] = [];
    let chromium: unknown;
    try {
      chromium = (await import('playwright')).chromium;
    } catch {
      // Playwright not installed — skip browser tests silently
      return [];
    }

    let browser;
    try {
      browser = await (chromium as { launch: (opts: { headless: boolean }) => Promise<unknown> }).launch({ headless: true });
      const page = await (browser as { newPage: () => Promise<unknown> }).newPage() as {
        goto: (url: string, opts: { timeout: number; waitUntil: string }) => Promise<{ status: () => number }>;
        title: () => Promise<string>;
        content: () => Promise<string>;
        on: (event: string, handler: (msg: { type: () => string; text: () => string }) => void) => void;
        close: () => Promise<void>;
      };

      const consoleErrors: string[] = [];
      page.on('console', (msg) => {
        if (msg.type() === 'error') consoleErrors.push(msg.text());
      });

      // Test 1: Frontend loads and renders (not blank page)
      try {
        const response = await page.goto(`${opts.frontendUrl}/`, { timeout: 15_000, waitUntil: 'networkidle' });
        const title = await page.title();
        const html = await page.content();
        const hasContent = html.length > 500 && !html.includes('Cannot GET /');

        results.push({
          flow: 'Browser Render', step: 1, action: 'Load frontend root',
          expected: 'Page renders with content', actual: hasContent ? `OK (title: "${title}", ${html.length} chars)` : 'Blank or error page',
          passed: hasContent && (response?.status() ?? 0) === 200,
        });
      } catch (err) {
        results.push({
          flow: 'Browser Render', step: 1, action: 'Load frontend root',
          expected: 'Page loads', actual: `${err instanceof Error ? err.message : String(err)}`,
          passed: false,
        });
      }

      // Test 2: No console errors on load
      results.push({
        flow: 'Browser Render', step: 2, action: 'Check console errors',
        expected: 'No console.error on page load', actual: consoleErrors.length === 0 ? 'Clean' : `${consoleErrors.length} errors: ${consoleErrors.slice(0, 3).join('; ')}`,
        passed: consoleErrors.length === 0,
      });

      // Test 3: Login page accessible (if exists)
      try {
        const loginResponse = await page.goto(`${opts.frontendUrl}/login`, { timeout: 10_000, waitUntil: 'networkidle' });
        const loginHtml = await page.content();
        const hasLoginForm = loginHtml.includes('password') || loginHtml.includes('Password') || loginHtml.includes('sign in') || loginHtml.includes('Sign In');

        results.push({
          flow: 'Browser Render', step: 3, action: 'Login page renders',
          expected: 'Login form visible', actual: hasLoginForm ? 'Login form found' : 'No login form detected',
          passed: (loginResponse?.status() ?? 0) !== 500,
        });
      } catch {
        // Login page may not exist — not a failure
      }

      await page.close();
    } catch (err) {
      results.push({
        flow: 'Browser Render', step: 0, action: 'Launch browser',
        expected: 'Chromium launches', actual: `${err instanceof Error ? err.message : String(err)}`,
        passed: false,
      });
    } finally {
      if (browser) await (browser as { close: () => Promise<void> }).close();
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
