import type { OptimizationProfileId } from "./constants";
import { estimateTokens } from "./tokens";
import { maskSecrets } from "./secrets";

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
 *
 * Keep this LEAN and never larger than cleaned prompt+context without reason.
 * Do NOT embed metadata notes in the model payload (that inflated stats, e.g.
 * 9766 → 9768 from a "Context:" label / Note: lines).
 */
function buildPayload(
  userPrompt: string,
  context: string | undefined
): string {
  const p = userPrompt.trim();
  const c = context?.trim();
  if (!c) return p;
  // Same shape as raw join — no "Context:" banner (that alone was +2 tokens)
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
      // keep first 2 occurrences of identical lines
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
      finalNotes = [
        "Already compact (unique document text — little/no duplicate noise to remove)",
      ];
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
 * Context optimizer — MVP rules engine.
 * Goal: never make the payload *worse*; shrink real noisy context when possible.
 * Unique prose/docs often land at 0% — that is correct, not a bug.
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

  // 3) Profile-specific dedupe
  const aggressive =
    profile === "log-analysis" || profile === "security-review";
  if (context) {
    const before = context.length;
    context = dedupeLines(context, aggressive);
    if (context.length < before) {
      notes.push(
        aggressive
          ? "Deduplicated repetitive log/context lines"
          : "Removed consecutive duplicate lines"
      );
    }
  }
  prompt = dedupeLines(prompt, false);

  // 4) Lean payload — notes stay in metadata only (not baked into model text)
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

  // Absolute guard: if still expanded, ship original cleaned join at original size floor
  if (result.expanded && result.optimizedTokens > originalTokens) {
    const safe = truncateToTokenBudget(rawCombined.trim(), maxTokens);
    result = finalizeStats(safe, originalTokens, profile, secretFindings, [
      ...notes,
      "Pass-through original (optimizer refused to expand)",
    ]);
    // force non-expanded display if estimate noise is 1 token
    if (result.optimizedTokens > originalTokens && result.optimizedTokens - originalTokens <= 2) {
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
