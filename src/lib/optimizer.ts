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
 * Keep this LEAN — heavy boilerplate was inflating tokens on small prompts
 * and made portal stats look broken (e.g. 7 → 75 tokens, 0% "savings").
 */
function buildPayload(
  profile: string,
  userPrompt: string,
  context: string | undefined,
  notes: string[]
): string {
  const p = userPrompt.trim();
  const c = context?.trim();

  // Tiny request, no context: pass through cleaned prompt only
  if (!c) {
    if (notes.length === 0 && (profile === "general" || !profile)) {
      return p;
    }
    const lines = [p];
    if (profile && profile !== "general") {
      lines.push("", `Profile: ${profile}`);
    }
    if (notes.length) {
      lines.push("", ...notes.map((n) => `Note: ${n}`));
    }
    return lines.join("\n");
  }

  // Prompt + context: minimal structure, no multi-paragraph instruction block
  const lines = [p, "", "Context:", c];
  if (profile && profile !== "general") {
    lines.push("", `Profile: ${profile}`);
  }
  if (notes.length) {
    lines.push("", ...notes.map((n) => `Note: ${n}`));
  }
  return lines.join("\n");
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

/**
 * Context optimizer — MVP rules engine.
 * Goal: never make small prompts *worse*; shrink real context when possible.
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

  // 4) Lean payload (no token-burning instruction essay)
  let optimized = buildPayload(profile, prompt, context, notes);

  // 5) Token budget
  const maxTokens = input.maxTokens ?? 24000;
  const beforeBudget = optimized;
  optimized = truncateToTokenBudget(optimized, maxTokens);
  if (optimized !== beforeBudget) {
    notes.push(`Truncated to ~${maxTokens} token budget`);
    // rebuild once so note is inside the text if we still have room
    optimized = truncateToTokenBudget(
      buildPayload(profile, prompt, context, notes),
      maxTokens
    );
  }

  const optimizedTokens = estimateTokens(optimized);
  const expanded = optimizedTokens > originalTokens;
  const saved = Math.max(0, originalTokens - optimizedTokens);
  const reductionPercent =
    originalTokens > 0 ? Math.round((saved / originalTokens) * 100) : 0;

  // If we somehow expanded a short prompt, fall back to cleaned pass-through
  // so portal stats never look like we made things worse without reason.
  if (expanded && originalTokens < 200) {
    const passthrough = truncateToTokenBudget(
      collapseBlankLines(
        [prompt, context].filter(Boolean).join("\n\n")
      ),
      maxTokens
    );
    const ptTokens = estimateTokens(passthrough);
    if (ptTokens <= optimizedTokens) {
      const ptSaved = Math.max(0, originalTokens - ptTokens);
      return {
        optimizedPrompt: passthrough,
        originalTokens,
        optimizedTokens: ptTokens,
        reductionPercent:
          originalTokens > 0
            ? Math.round((ptSaved / originalTokens) * 100)
            : 0,
        expanded: ptTokens > originalTokens,
        profile,
        secretsMasked: secretFindings.length > 0,
        secretFindings,
        notes: notes.length
          ? notes
          : ["Pass-through (small prompt; no safe reduction)"],
      };
    }
  }

  return {
    optimizedPrompt: optimized,
    originalTokens,
    optimizedTokens,
    reductionPercent,
    expanded,
    profile,
    secretsMasked: secretFindings.length > 0,
    secretFindings,
    notes: notes.length
      ? notes
      : originalTokens === optimizedTokens
        ? ["No reduction needed (already compact)"]
        : [],
  };
}
