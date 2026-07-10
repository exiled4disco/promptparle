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
  profile: string;
  secretsMasked: boolean;
  secretFindings: string[];
  notes: string[];
};

const PROFILE_INSTRUCTIONS: Record<string, string> = {
  general:
    "Clean the request, remove filler, preserve the user's intent and constraints.",
  developer:
    "Preserve code structure, filenames, stack traces, function names, and exact errors. Remove unrelated chatter.",
  "security-review":
    "Preserve IPs, domains, ports, protocols, logs, firewall rules, auth events, and risk indicators. Remove noise.",
  "log-analysis":
    "Deduplicate repetitive log lines, keep outliers and time windows, retain representative raw events.",
  documentation:
    "Organize material, remove repetition, preserve required terms and structure for clear docs.",
  "executive-summary":
    "Reduce technical noise into concise business-readable context while keeping decisions and risks.",
};

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

/** Drop exact duplicate consecutive lines; for logs also drop high-frequency repeats. */
function dedupeLines(text: string, aggressive: boolean): string {
  const lines = text.split("\n");
  const out: string[] = [];
  const counts = new Map<string, number>();
  let prev = "";

  for (const line of lines) {
    const normalized = line.trimEnd();
    if (normalized === prev && normalized.trim() !== "") {
      continue; // consecutive duplicate
    }
    if (aggressive && normalized.trim()) {
      const key = normalized.trim();
      const c = (counts.get(key) || 0) + 1;
      counts.set(key, c);
      // keep first 2 occurrences of identical log lines
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
  // keep head + tail (errors often at end)
  const maxChars = maxTokens * 4;
  const head = Math.floor(maxChars * 0.7);
  const tail = Math.floor(maxChars * 0.25);
  if (text.length <= head + tail + 80) return text;
  return (
    text.slice(0, head) +
    "\n\n[... context truncated by PromptParle to fit token budget ...]\n\n" +
    text.slice(-tail)
  );
}

function buildStructuredPrompt(
  profile: string,
  userPrompt: string,
  context: string | undefined,
  notes: string[]
): string {
  const instruction =
    PROFILE_INSTRUCTIONS[profile] || PROFILE_INSTRUCTIONS.general;

  const parts = [
    "User goal:",
    userPrompt.trim(),
    "",
    "Optimization profile:",
    `${profile} — ${instruction}`,
  ];

  if (context?.trim()) {
    parts.push("", "Relevant context:", context.trim());
  }

  parts.push(
    "",
    "Instructions:",
    "- Answer the user goal directly.",
    "- Use only the relevant context provided.",
    "- Keep output practical and concise unless asked otherwise."
  );

  if (notes.length) {
    parts.push("", "PromptParle notes:", ...notes.map((n) => `- ${n}`));
  }

  return parts.join("\n");
}

/**
 * Context optimizer — MVP rules engine.
 * Not ML-based yet; focuses on structure, dedupe, secrets, budget.
 */
export function optimizePrompt(input: OptimizeInput): OptimizeResult {
  const profile = input.profile || "general";
  const notes: string[] = [];

  const rawCombined = [input.prompt, input.context]
    .filter(Boolean)
    .join("\n\n");
  const originalTokens = estimateTokens(rawCombined);

  // 1) Secret mask first (never forward secrets we can detect)
  const promptScan = maskSecrets(input.prompt || "");
  const contextScan = maskSecrets(input.context || "");
  const secretFindings = [
    ...new Set([...promptScan.findings, ...contextScan.findings]),
  ];
  if (secretFindings.length) {
    notes.push(
      `Masked potential secrets: ${secretFindings.join(", ")}`
    );
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

  // 4) Structure
  let optimized = buildStructuredPrompt(profile, prompt, context, []);

  // 5) Token budget
  const maxTokens = input.maxTokens ?? 24000;
  const beforeBudget = optimized;
  optimized = truncateToTokenBudget(optimized, maxTokens);
  if (optimized !== beforeBudget) {
    notes.push(`Truncated to ~${maxTokens} token budget`);
  }

  // Re-attach notes into structured form once
  if (notes.length) {
    optimized = buildStructuredPrompt(
      profile,
      prompt,
      context
        ? truncateToTokenBudget(context, Math.floor(maxTokens * 0.75))
        : undefined,
      notes
    );
    optimized = truncateToTokenBudget(optimized, maxTokens);
  }

  const optimizedTokens = estimateTokens(optimized);
  const saved = Math.max(0, originalTokens - optimizedTokens);
  const reductionPercent =
    originalTokens > 0 ? Math.round((saved / originalTokens) * 100) : 0;

  return {
    optimizedPrompt: optimized,
    originalTokens,
    optimizedTokens,
    reductionPercent,
    profile,
    secretsMasked: secretFindings.length > 0,
    secretFindings,
    notes,
  };
}
