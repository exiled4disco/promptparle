import type { OptimizationProfileId } from "./constants";
import { estimateTokens } from "./tokens";
import { maskSecrets } from "./secrets";
import { compressDocument, looksLikeDocument } from "./document-compress";

export type OptimizeInput = {
  prompt: string;
  context?: string;
  profile?: OptimizationProfileId | string;
  /** soft cap for optimized output tokens (estimate) */
  maxTokens?: number;
};

export type OptimizeResult = {
  optimizedPrompt: string;
  originalTokens: number;
  optimizedTokens: number;
  reductionPercent: number;
  /** true when final payload is larger than the raw input (should be rare) */
  expanded: boolean;
  profile: string;
  secretsMasked: boolean;
  secretFindings: string[];
  notes: string[];
};

/**
 * Build the payload that actually goes to the model.
 * Notes stay in metadata only — never bake labels that inflate token counts.
 */
function buildPayload(
  userPrompt: string,
  context: string | undefined
): string {
  const p = userPrompt.trim();
  const c = context?.trim();
  if (!c) return p;
  return `${p}\n\n${c}`;
}

function collapseBlankLines(text: string): string {
  return text.replace(/\n{3,}/g, "\n\n").trim();
}

function stripChattyFiller(text: string): string {
  const lines = text.split("\n");
  const filler =
    /^(please\s+)?(kindly\s+)?(i\s+hope\s+this\s+helps|as\s+an\s+ai|thanks\s+in\s+advance|just\s+wanted\s+to\s+say)[:\s.]*/i;
  return lines
    .filter((line) => {
      const t = line.trim();
      if (!t) return true;
      if (filler.test(t) && t.length < 80) return false;
      return true;
    })
    .join("\n");
}

/**
 * Drop exact duplicate consecutive lines.
 * Aggressive mode also caps non-consecutive identical lines (logs).
 */
function dedupeLines(text: string, aggressive: boolean): string {
  const lines = text.split("\n");
  const out: string[] = [];
  const counts = new Map<string, number>();
  let prev = "";

  for (const line of lines) {
    const normalized = line.trimEnd();
    if (normalized === prev && normalized.trim() !== "") {
      continue;
    }
    if (aggressive && normalized.trim()) {
      const key = normalized.trim();
      const c = (counts.get(key) || 0) + 1;
      counts.set(key, c);
      if (c > 2) continue;
    }
    out.push(line);
    prev = normalized;
  }
  return out.join("\n");
}

function truncateToTokenBudget(text: string, maxTokens: number): string {
  const est = estimateTokens(text);
  if (est <= maxTokens) return text;
  const maxChars = maxTokens * 4;
  const head = Math.floor(maxChars * 0.7);
  const tail = Math.floor(maxChars * 0.25);
  if (text.length <= head + tail + 80) return text;
  return (
    text.slice(0, head) +
    "\n\n[... truncated by PromptParle to fit token budget ...]\n\n" +
    text.slice(-tail)
  );
}

function finalizeStats(
  optimizedPrompt: string,
  originalTokens: number,
  profile: string,
  secretFindings: string[],
  notes: string[]
): OptimizeResult {
  const optimizedTokens = estimateTokens(optimizedPrompt);
  const expanded = optimizedTokens > originalTokens;
  const saved = Math.max(0, originalTokens - optimizedTokens);
  const reductionPercent =
    originalTokens > 0 ? Math.round((saved / originalTokens) * 100) : 0;

  let finalNotes = notes;
  if (finalNotes.length === 0) {
    if (expanded) {
      finalNotes = ["Could not compress further without losing content"];
    } else if (saved === 0) {
      finalNotes = ["No reduction applied"];
    }
  }

  return {
    optimizedPrompt,
    originalTokens,
    optimizedTokens,
    reductionPercent,
    expanded,
    profile,
    secretsMasked: secretFindings.length > 0,
    secretFindings,
    notes: finalNotes,
  };
}

/**
 * Context optimizer.
 *
 * Paths:
 *  - Logs / repetitive noise → aggressive line dedupe
 *  - Well-formed documents → query-aware section keep + densify + chrome strip
 *  - Always refuse to expand the payload vs the user input
 */
export function optimizePrompt(input: OptimizeInput): OptimizeResult {
  const profile = input.profile || "general";
  const notes: string[] = [];

  const rawCombined = [input.prompt, input.context]
    .filter(Boolean)
    .join("\n\n");
  const originalTokens = estimateTokens(rawCombined);

  // 1) Secret mask first
  const promptScan = maskSecrets(input.prompt || "");
  const contextScan = maskSecrets(input.context || "");
  const secretFindings = [
    ...new Set([...promptScan.findings, ...contextScan.findings]),
  ];
  if (secretFindings.length) {
    notes.push(`Masked secrets: ${secretFindings.join(", ")}`);
  }

  let prompt = promptScan.text;
  let context = contextScan.text || undefined;

  // 2) Clean filler / whitespace
  prompt = collapseBlankLines(stripChattyFiller(prompt));
  if (context) {
    context = collapseBlankLines(stripChattyFiller(context));
  }

  // 3) Path selection: document compress vs log dedupe
  const aggressiveLog =
    profile === "log-analysis" || profile === "security-review";

  if (context) {
    const docMode =
      profile === "documentation" ||
      profile === "executive-summary" ||
      looksLikeDocument(context);

    if (docMode && !aggressiveLog) {
      const doc = compressDocument(context, {
        prompt,
        profile,
      });
      if (doc.applied) {
        context = doc.text;
        notes.push(...doc.notes);
      } else if (doc.notes.length) {
        notes.push(...doc.notes);
      }
      // light consecutive dedupe still helps after doc compress
      context = dedupeLines(context, false);
    } else {
      const before = context.length;
      context = dedupeLines(context, aggressiveLog);
      if (context.length < before) {
        notes.push(
          aggressiveLog
            ? "Deduplicated repetitive log/context lines"
            : "Removed consecutive duplicate lines"
        );
      }
      // If it still looks like a long unique doc after mild dedupe, run doc path
      if (looksLikeDocument(context) && context.length > 1500) {
        const doc = compressDocument(context, { prompt, profile });
        if (doc.applied) {
          context = doc.text;
          notes.push(...doc.notes);
        }
      }
    }
  }
  prompt = dedupeLines(prompt, false);

  // 4) Lean payload
  let optimized = buildPayload(prompt, context);

  // 5) Token budget
  const maxTokens = input.maxTokens ?? 24000;
  const beforeBudget = optimized;
  optimized = truncateToTokenBudget(optimized, maxTokens);
  if (optimized !== beforeBudget) {
    notes.push(`Truncated to ~${maxTokens} token budget`);
  }

  let result = finalizeStats(
    optimized,
    originalTokens,
    profile,
    secretFindings,
    notes
  );

  // 6) NEVER expand vs the user's original input
  if (result.expanded) {
    const passthrough = truncateToTokenBudget(
      collapseBlankLines(
        [promptScan.text, contextScan.text].filter(Boolean).join("\n\n")
      ),
      maxTokens
    );
    const pt = finalizeStats(
      passthrough,
      originalTokens,
      profile,
      secretFindings,
      notes.length
        ? [...notes, "Used pass-through to avoid expansion"]
        : ["Pass-through (no safe reduction without growing the payload)"]
    );
    if (pt.optimizedTokens <= result.optimizedTokens) {
      result = pt;
    }
  }

  if (result.expanded && result.optimizedTokens > originalTokens) {
    const safe = truncateToTokenBudget(rawCombined.trim(), maxTokens);
    result = finalizeStats(safe, originalTokens, profile, secretFindings, [
      ...notes,
      "Pass-through original (optimizer refused to expand)",
    ]);
    if (
      result.optimizedTokens > originalTokens &&
      result.optimizedTokens - originalTokens <= 2
    ) {
      result = {
        ...result,
        optimizedTokens: originalTokens,
        reductionPercent: 0,
        expanded: false,
        notes: [
          ...result.notes,
          "Rounded tiny estimator noise to 0% (already compact)",
        ],
      };
    }
  }

  return result;
}
