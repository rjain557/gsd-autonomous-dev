// ═══════════════════════════════════════════════════════════
// GSD V6 — Slice Planner
// Decomposes a milestone into one or more slices. Reads an
// optional `memory/milestones/M{id}/ROADMAP.md` with a "## Slices"
// section, or falls back to a single default slice.
// ═══════════════════════════════════════════════════════════

import * as fs from 'fs';
import * as path from 'path';
import type { MilestoneId, Slice, SliceId } from './types';

export interface SlicePlan {
  slices: Slice[];
  source: 'roadmap' | 'default';
}

export interface SlicePlannerOptions {
  milestoneId: MilestoneId;
  vaultPath: string;
  milestoneName: string;
  description: string;
}

/**
 * Parse a roadmap markdown file that looks like:
 *
 *   ## Slices
 *   - S01: thread archive — archive/unarchive flow
 *   - S02: thread restore — restore archived threads (depends on S01)
 *   - S03: bulk archive  — multi-select UI
 */
export class SlicePlanner {
  static plan(opts: SlicePlannerOptions): SlicePlan {
    const roadmapPath = path.join(opts.vaultPath, 'milestones', opts.milestoneId, 'ROADMAP.md');
    if (fs.existsSync(roadmapPath)) {
      const raw = fs.readFileSync(roadmapPath, 'utf8');
      const slices = SlicePlanner.parseRoadmap(raw, opts.milestoneId);
      if (slices.length > 0) {
        return { slices, source: 'roadmap' };
      }
    }
    // Default: single slice covering the whole milestone
    return {
      slices: [
        {
          id: 'S01',
          milestoneId: opts.milestoneId,
          name: `${opts.milestoneName} (default slice)`,
          description: opts.description,
          status: 'pending',
          dependsOnSliceIds: [],
          startedAt: null,
          completedAt: null,
        },
      ],
      source: 'default',
    };
  }

  static parseRoadmap(markdown: string, milestoneId: MilestoneId): Slice[] {
    const slices: Slice[] = [];

    // Find "## Slices" section
    const slicesSection = markdown.match(/##\s+Slices\s*\n([\s\S]*?)(?:\n##\s|\n?$)/i);
    if (!slicesSection) return [];

    const body = slicesSection[1];
    const lineRe = /^\s*-\s*(S\d{2,3}(?:[-_][a-z0-9]+)?)\s*:\s*([^—\-\n]+?)(?:\s*—\s*(.+))?$/gim;

    let match: ReturnType<RegExp['exec']> = null;
    while ((match = lineRe.exec(body)) !== null) {
      const sliceId = match[1] as SliceId;
      const name = match[2].trim();
      const description = (match[3] ?? '').trim();

      // Parse "(depends on SXX, SYY)" from description
      const depsMatch = description.match(/\(depends on ([A-Z0-9, ]+)\)/i);
      const dependsOn: SliceId[] = depsMatch
        ? depsMatch[1].split(',').map((s) => s.trim()).filter((s) => /^S\d+/.test(s))
        : [];

      slices.push({
        id: sliceId,
        milestoneId,
        name,
        description: description.replace(/\(depends on [^)]+\)/i, '').trim(),
        status: 'pending',
        dependsOnSliceIds: dependsOn,
        startedAt: null,
        completedAt: null,
      });
    }

    return slices;
  }
}
