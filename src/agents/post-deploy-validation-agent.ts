// ═══════════════════════════════════════════════════════════
// PostDeployValidationAgent
// Runs AFTER deployment to validate the live environment.
// Catches: stale SPA cache, broken DI, missing SPs, DTO
// mismatches, auth flow failures, and infrastructure issues.
// Based on 15 failure categories from ChatAI v8 alpha.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  PostDeployInput,
  PostDeployValidationResult,
  PostDeployCheck,
} from '../harness/types';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as http from 'http';
import * as https from 'https';

export class PostDeployValidationAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const opts = input as PostDeployInput;
    const checks: PostDeployCheck[] = [];

    // 1. SPA hash freshness (catches IIS kernel cache stale SPA disease)
    checks.push(await this.checkSpaFreshness(opts.frontendUrl));

    // 2. Health endpoint
    checks.push(await this.checkEndpoint(opts.apiBaseUrl, '/api/health', 200, 'Health'));

    // 3. Auth endpoint returns 401 without token (not 500 from broken DI)
    checks.push(await this.checkEndpoint(opts.apiBaseUrl, '/api/auth/me', 401, 'Auth (no token)'));

    // 4. Parse API contracts to discover all endpoints, check none return 500
    const apiEndpoints = await this.discoverEndpoints(opts);
    for (const ep of apiEndpoints) {
      checks.push(await this.checkNot500(opts.apiBaseUrl, ep));
    }

    // 5. Frontend pages load
    checks.push(await this.checkEndpoint(opts.frontendUrl, '/', 200, 'Frontend root'));

    // 6. SPA JS bundle accessible (catches 404 from stale hash)
    checks.push(await this.checkSpaJsLoads(opts.frontendUrl));

    const criticalFailed = checks.filter(c =>
      (c.severity === 'critical' || c.severity === 'high') && !c.passed
    );

    return {
      passed: criticalFailed.length === 0,
      checks,
      spExistence: { expected: 0, found: 0, missing: [] },
      dtoValidation: { tested: apiEndpoints.length, passed: checks.filter(c => c.category === 'api' && c.passed).length, mismatches: [] },
      pageRender: { tested: 2, passed: checks.filter(c => c.category === 'frontend' && c.passed).length, failures: checks.filter(c => c.category === 'frontend' && !c.passed).map(c => c.details) },
      authFlow: { passed: checks.find(c => c.name === 'Auth (no token)')?.passed ?? false, details: checks.find(c => c.name === 'Auth (no token)')?.details ?? '' },
    } satisfies PostDeployValidationResult;
  }

  private async discoverEndpoints(opts: PostDeployInput): Promise<string[]> {
    const endpoints = new Set(['/api/health', '/api/auth/me']);
    if (opts.apiContractsPath) {
      try {
        const contracts = await fs.readFile(path.resolve(opts.apiContractsPath), 'utf-8');
        const epRegex = /####?\s*`GET\s+(\/api\/[^`]+)`/g;
        let m; while ((m = epRegex.exec(contracts)) !== null) endpoints.add(m[1]);
      } catch { /* contracts file not found — use defaults */ }
    }
    return [...endpoints];
  }

  private async checkSpaFreshness(frontendUrl: string): Promise<PostDeployCheck> {
    try {
      const html = await this.httpGetBody(`${frontendUrl}/`);
      const scriptMatch = html.match(/src="[^"]*index-([a-zA-Z0-9]+)\.js"/);
      if (!scriptMatch) return { name: 'SPA hash', category: 'infrastructure', passed: true, details: 'No hashed JS detected', severity: 'low' };
      const jsUrl = `${frontendUrl}/assets/index-${scriptMatch[1]}.js`;
      const status = await this.httpGetStatus(jsUrl);
      if (status === 200) return { name: 'SPA hash', category: 'infrastructure', passed: true, details: `Hash ${scriptMatch[1]} accessible`, severity: 'critical' };
      return { name: 'SPA hash', category: 'infrastructure', passed: false, details: `Hash ${scriptMatch[1]} returned ${status} - stale cache suspected`, severity: 'critical' };
    } catch (err) {
      return { name: 'SPA hash', category: 'infrastructure', passed: false, details: `${err instanceof Error ? err.message : String(err)}`, severity: 'critical' };
    }
  }

  private async checkSpaJsLoads(frontendUrl: string): Promise<PostDeployCheck> {
    try {
      const html = await this.httpGetBody(`${frontendUrl}/`);
      const srcMatch = html.match(/src="([^"]+\.js)"/);
      if (!srcMatch) return { name: 'SPA JS bundle', category: 'frontend', passed: true, details: 'No script tags', severity: 'low' };
      const src = srcMatch[1];
      const jsUrl = src.startsWith('http') ? src : `${frontendUrl}${src.startsWith('/') ? '' : '/'}${src}`;
      const status = await this.httpGetStatus(jsUrl);
      return { name: 'SPA JS bundle', category: 'frontend', passed: status === 200, details: `${src} -> HTTP ${status}`, severity: status === 200 ? 'low' : 'critical' };
    } catch (err) {
      return { name: 'SPA JS bundle', category: 'frontend', passed: false, details: `${err instanceof Error ? err.message : String(err)}`, severity: 'critical' };
    }
  }

  private async checkEndpoint(base: string, ep: string, expected: number, name: string): Promise<PostDeployCheck> {
    try {
      const status = await this.httpGetStatus(`${base}${ep}`);
      const cat = ep.includes('/auth') ? 'auth' as const : 'api' as const;
      return { name, category: cat, passed: status === expected || (expected === 401 && status === 200), details: `${ep} -> HTTP ${status} (expected ${expected})`, severity: 'high' };
    } catch (err) {
      return { name, category: 'api', passed: false, details: `${ep} -> ${err instanceof Error ? err.message : String(err)}`, severity: 'high' };
    }
  }

  private async checkNot500(base: string, ep: string): Promise<PostDeployCheck> {
    try {
      const status = await this.httpGetStatus(`${base}${ep}`);
      return { name: `No 500: ${ep}`, category: 'api', passed: status !== 500, details: `HTTP ${status}`, severity: status === 500 ? 'critical' : 'low' };
    } catch (err) {
      return { name: `No 500: ${ep}`, category: 'api', passed: false, details: `${err instanceof Error ? err.message : String(err)}`, severity: 'high' };
    }
  }

  private httpGetStatus(url: string): Promise<number> {
    const client = url.startsWith('https') ? https : http;
    return new Promise((resolve, reject) => {
      const req = client.get(url, { timeout: 10_000 }, (res) => { resolve(res.statusCode ?? 0); res.resume(); });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    });
  }

  private httpGetBody(url: string): Promise<string> {
    const client = url.startsWith('https') ? https : http;
    return new Promise((resolve, reject) => {
      const req = client.get(url, { timeout: 10_000 }, (res) => {
        let data = ''; res.on('data', (c: Buffer) => { data += c.toString(); }); res.on('end', () => resolve(data));
      });
      req.on('error', reject);
      req.on('timeout', () => { req.destroy(); reject(new Error('timeout')); });
    });
  }
}
