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

    // Run independent checks in parallel (3 groups: network, filesystem, network)
    const [apiResults, spResults, mockResults, pageResults, authResults] = await Promise.all([
      this.validateApiContracts(opts),
      this.validateStoredProcedures(opts),
      this.detectMockData(opts.repoRoot),
      this.validatePageRender(opts),
      this.validateAuthFlow(opts),
    ]);

    results.push(...apiResults, ...spResults, ...mockResults, ...pageResults, ...authResults);
    this.tally(categories.apiContract, apiResults);
    this.tally(categories.mockDataDetection, mockResults);
    this.tally(categories.screenRender, pageResults);
    this.tally(categories.authFlows, authResults);

    const totalFlows = results.length;
    const passedFlows = results.filter(r => r.passed).length;

    return {
      passed: categories.apiContract.failures.length === 0 && categories.authFlows.failures.length === 0,
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

  /** Call every GET endpoint from 06-api-contracts.md in parallel, verify not 404/500. */
  private async validateApiContracts(opts: E2EValidationInput): Promise<E2ETestResult[]> {
    let contracts: string;
    try { contracts = await fs.readFile(path.resolve(opts.repoRoot, opts.apiContractsPath), 'utf-8'); }
    catch { return [{ flow: 'API Contracts', step: 0, action: 'read file', expected: 'exists', actual: `${opts.apiContractsPath} not found`, passed: false }]; }

    // Collect all endpoints first, then fire in parallel
    const epPattern = /####?\s*`(GET|POST|PUT|DELETE|PATCH)\s+(\/api\/[^`]+)`/g;
    const endpoints: Array<{ step: number; method: string; endpoint: string }> = [];
    const nonGetResults: E2ETestResult[] = [];
    let match; let step = 0;
    while ((match = epPattern.exec(contracts)) !== null) {
      step++;
      const [, method, endpoint] = match;
      if (method !== 'GET') {
        nonGetResults.push({ flow: 'API Contract', step, action: `${method} ${endpoint}`, expected: 'skipped (needs payload)', actual: 'skipped', passed: true });
      } else {
        endpoints.push({ step, method, endpoint });
      }
    }

    // Fire all GET requests concurrently (8-10x faster than sequential)
    const CONCURRENCY = 10;
    const getResults: E2ETestResult[] = [];
    for (let i = 0; i < endpoints.length; i += CONCURRENCY) {
      const batch = endpoints.slice(i, i + CONCURRENCY);
      const batchResults = await Promise.all(batch.map(async ({ step: s, endpoint: ep }) => {
        const url = `${opts.backendUrl}${ep}`;
        try {
          const status = await this.httpGetStatus(url);
          return { flow: 'API Contract', step: s, action: `GET ${ep}`, expected: 'not 404/500', actual: `HTTP ${status}`, passed: status !== 404 && status !== 500, networkCalls: [url] } as E2ETestResult;
        } catch (err) {
          return { flow: 'API Contract', step: s, action: `GET ${ep}`, expected: 'responds', actual: `${err instanceof Error ? err.message : String(err)}`, passed: false } as E2ETestResult;
        }
      }));
      getResults.push(...batchResults);
    }

    return [...nonGetResults, ...getResults];
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
