// ═══════════════════════════════════════════════════════════
// LLM-as-Judge for CodeReviewAgent Output Quality
// Scores: thoroughness (1-5), actionability (1-5),
// false-positive-rate (1-5)
// ═══════════════════════════════════════════════════════════

import type { ReviewResult } from '../../harness/types';

export interface ReviewQualityScore {
  thoroughness: number;   // 1-5: did it catch all issues?
  actionability: number;  // 1-5: are suggested fixes clear?
  falsePositiveRate: number; // 1-5: how many findings are noise? (5=low noise)
  overall: number;        // average of above
  rationale: string;
}

export function scoreReviewQuality(
  reviewResult: ReviewResult,
  knownIssueCount: number,
  knownSecurityIssues: number,
): ReviewQualityScore {
  // Thoroughness: did it find the known issues?
  const foundCount = reviewResult.issues.length;
  const thoroughnessRatio = Math.min(foundCount / Math.max(knownIssueCount, 1), 1);
  const thoroughness = Math.ceil(thoroughnessRatio * 5);

  // Actionability: do issues have suggested fixes?
  const withFixes = reviewResult.issues.filter(i => i.suggestedFix).length;
  const fixRatio = foundCount > 0 ? withFixes / foundCount : 0;
  const actionability = Math.ceil(fixRatio * 5) || 1;

  // False positive rate: compare found security issues to known
  const foundSecurity = reviewResult.securityFlags.length;
  const falsePositives = Math.max(0, foundSecurity - knownSecurityIssues);
  const fpRate = foundSecurity > 0 ? falsePositives / foundSecurity : 0;
  const falsePositiveRate = Math.ceil((1 - fpRate) * 5);

  const overall = Math.round((thoroughness + actionability + falsePositiveRate) / 3);

  const rationale = [
    `Found ${foundCount}/${knownIssueCount} expected issues (thoroughness=${thoroughness})`,
    `${withFixes}/${foundCount} issues have suggested fixes (actionability=${actionability})`,
    `${falsePositives} false positive security flags (FP rate score=${falsePositiveRate})`,
  ].join('. ');

  return {
    thoroughness,
    actionability,
    falsePositiveRate,
    overall,
    rationale,
  };
}
