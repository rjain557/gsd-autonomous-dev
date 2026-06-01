// ═══════════════════════════════════════════════════════════
// PMAgent
// Program manager for calendar-time work. Replaces the human PM
// from myJian §10.15. Tracks vendor relationships, renewal calendar,
// milestone progress, surfaces RJain action items. Cross-coordinates
// with SecurityAgent / ComplianceAgent / LegalAgent outputs.
// ═══════════════════════════════════════════════════════════

import { BaseAgent } from '../harness/base-agent';
import type {
  AgentInput,
  AgentOutput,
  PMAgentInput,
  PMStatusReport,
  PMActionItem,
  VendorStatus,
  RenewalItem,
  MilestoneStatus,
  PMBlocker,
  SignatoryItem,
  SignatoryAction,
  PMReportType,
} from '../harness/types';
import * as fs from 'fs';
import * as path from 'path';

export class PMAgent extends BaseAgent {
  protected async run(input: AgentInput): Promise<AgentOutput> {
    const { report_type, window, include_archived_vendors } = input as PMAgentInput;

    const [vendorRegistry, renewalCalendar, milestoneCatalog, calendarTracks] = await Promise.all([
      this.loadVendorRegistry(),
      this.loadRenewalCalendar(),
      this.loadMilestoneCatalog(),
      this.loadCalendarTracks(),
    ]);

    const upstreamSignatoryActions = await this.collectUpstreamSignatoryActions(window);

    const systemPrompt = await this.buildSystemPrompt();

    const userMessage = [
      '## Report Type',
      report_type,
      '',
      '## Window',
      window ? `${window.start} to ${window.end}` : '(no window — point-in-time)',
      '',
      '## Vendor Registry',
      vendorRegistry,
      '',
      '## Renewal Calendar',
      renewalCalendar,
      '',
      '## Milestone Catalog',
      milestoneCatalog,
      '',
      '## Calendar-Time Tracks',
      calendarTracks,
      '',
      '## Upstream signatory actions (last 7 days, from Security/Compliance/Legal agents)',
      upstreamSignatoryActions.length > 0 ? JSON.stringify(upstreamSignatoryActions, null, 2) : '(none)',
      '',
      '## Instructions',
      '',
      'Run FIVE passes:',
      '1. **Vendor relationship sweep**: for each vendor, status + days-since-activity + next action.',
      '2. **Renewal calendar**: for each item, days_until + preparation status. Elevate <60 days as urgent.',
      '3. **Milestone delta**: read milestone state, report which phase is in-progress + % complete + ETA.',
      '4. **Cross-agent coordination**: consolidate upstream signatoryActions into RJain action items.',
      '5. **Status report generation**: produce the markdown report.',
      '',
      'Return a JSON PMStatusReport with: report_date, report_type, status_report_markdown (full markdown), rjain_action_items, vendor_relationships, urgent_renewals, milestone_status, blockers, artifacts_awaiting_signature.',
      '',
      'For the status_report_markdown, follow this format:',
      '```',
      '# Weekly Status — <date>',
      '## RJain Action Items',
      '## Vendor Relationships',
      '## Renewal Calendar (next 90 days)',
      '## Milestone Status',
      '## Blockers',
      '```',
      '',
      'Output ONLY valid JSON.',
    ].join('\n');

    const schema = {
      type: 'object' as const,
      properties: {
        report_date: { type: 'string' },
        report_type: { type: 'string' },
        status_report_markdown: { type: 'string' },
        rjain_action_items: { type: 'array' },
        vendor_relationships: { type: 'array' },
        urgent_renewals: { type: 'array' },
        milestone_status: { type: 'array' },
        blockers: { type: 'array' },
        artifacts_awaiting_signature: { type: 'array' },
      },
      required: ['report_date', 'report_type', 'status_report_markdown', 'rjain_action_items'],
    };

    const response = await this.callLLM(systemPrompt, userMessage, schema);
    return this.parseResult(response, report_type, upstreamSignatoryActions);
  }

  private async loadVendorRegistry(): Promise<string> {
    return this.readKnowledgeFile('vendor-relationships.md', '(vendor-relationships.md missing — initialize before next run)');
  }

  private async loadRenewalCalendar(): Promise<string> {
    return this.readKnowledgeFile('renewal-calendar.md', '(renewal-calendar.md missing — initialize on first run)');
  }

  private async loadMilestoneCatalog(): Promise<string> {
    return this.readKnowledgeFile('milestone-catalog.md', '(milestone-catalog.md missing)');
  }

  private async loadCalendarTracks(): Promise<string> {
    return this.readKnowledgeFile('calendar-time-tracks.md', '(calendar-time-tracks.md missing)');
  }

  private async readKnowledgeFile(name: string, fallback: string): Promise<string> {
    const p = path.join(process.cwd(), 'memory', 'knowledge', name);
    try {
      return await fs.promises.readFile(p, 'utf-8');
    } catch {
      return fallback;
    }
  }

  private async collectUpstreamSignatoryActions(window?: { start: string; end: string }): Promise<SignatoryAction[]> {
    // Read the last 7 days of decision logs from security-agent, compliance-agent, legal-agent
    const decisionsDir = path.join(process.cwd(), 'memory', 'decisions');
    const cutoffMs = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const actions: SignatoryAction[] = [];

    try {
      const entries = await fs.promises.readdir(decisionsDir, { withFileTypes: true });
      for (const entry of entries) {
        if (!entry.isFile() || !entry.name.endsWith('.json')) continue;
        const filePath = path.join(decisionsDir, entry.name);
        const stat = await fs.promises.stat(filePath);
        if (stat.mtimeMs < cutoffMs) continue;
        try {
          const body = await fs.promises.readFile(filePath, 'utf-8');
          const parsed = JSON.parse(body);
          if (Array.isArray(parsed.signatoryActions)) {
            actions.push(...(parsed.signatoryActions as SignatoryAction[]));
          }
        } catch {
          // skip malformed
        }
      }
    } catch {
      // decisions dir missing — skip
    }

    return actions;
  }

  private parseResult(
    llmResponse: string,
    reportType: PMReportType,
    upstreamSignatories: SignatoryAction[],
  ): PMStatusReport {
    const parsed = this.extractJSON<Record<string, unknown>>(llmResponse);

    const report_date = String(parsed.report_date ?? new Date().toISOString().slice(0, 10));

    const rjain_action_items: PMActionItem[] = Array.isArray(parsed.rjain_action_items)
      ? (parsed.rjain_action_items as PMActionItem[])
      : [];

    // Fold upstream signatory actions into action items if the LLM missed them
    for (const sa of upstreamSignatories) {
      const alreadyIncluded = rjain_action_items.some(it => it.description?.includes(sa.description));
      if (!alreadyIncluded) {
        rjain_action_items.push({
          category: sa.category === 'legal-execution' ? 'signature' :
                     sa.category === 'vendor-application' ? 'vendor-call' :
                     sa.category === 'compliance-attestation' ? 'signature' :
                     'review',
          description: sa.description,
          due_date: sa.dueDate,
          priority: sa.blocking ? 'urgent' : 'high',
          artifact_path: sa.artifactPath,
        });
      }
    }

    const vendor_relationships: VendorStatus[] = Array.isArray(parsed.vendor_relationships)
      ? (parsed.vendor_relationships as VendorStatus[])
      : [];

    const urgent_renewals: RenewalItem[] = Array.isArray(parsed.urgent_renewals)
      ? (parsed.urgent_renewals as RenewalItem[])
      : [];

    const milestone_status: MilestoneStatus[] = Array.isArray(parsed.milestone_status)
      ? (parsed.milestone_status as MilestoneStatus[])
      : [];

    const blockers: PMBlocker[] = Array.isArray(parsed.blockers)
      ? (parsed.blockers as PMBlocker[])
      : [];

    const artifacts_awaiting_signature: SignatoryItem[] = Array.isArray(parsed.artifacts_awaiting_signature)
      ? (parsed.artifacts_awaiting_signature as SignatoryItem[])
      : upstreamSignatories
          .filter(sa => sa.artifactPath)
          .map(sa => ({
            document_type: sa.category,
            artifact_path: sa.artifactPath!,
            signatory: sa.signatory,
            due_date: sa.dueDate,
          }));

    return {
      report_date,
      report_type: reportType,
      status_report_markdown: String(parsed.status_report_markdown ?? ''),
      rjain_action_items,
      vendor_relationships,
      urgent_renewals,
      milestone_status,
      blockers,
      artifacts_awaiting_signature,
    };
  }
}
