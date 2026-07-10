import { getPlanLimits, type PlanLimits } from "./plans";

export type StoredPromptTexts = {
  originalText: string | null;
  optimizedText: string | null;
  originalTruncated: boolean;
  optimizedTruncated: boolean;
  promptPreview: string | null;
};

/** Build the "before" payload the user sent (prompt + optional context). */
export function buildOriginalText(prompt: string, context?: string | null): string {
  const p = (prompt || "").trim();
  const c = (context || "").trim();
  if (!c) return p;
  return `## Prompt\n${p}\n\n## Context\n${c}`;
}

function clip(text: string, maxChars: number): { text: string; truncated: boolean } {
  if (maxChars <= 0) return { text: "", truncated: text.length > 0 };
  if (text.length <= maxChars) return { text, truncated: false };
  const keep = Math.max(0, maxChars - 24);
  return {
    text: text.slice(0, keep) + "\n\n…[truncated by plan]",
    truncated: true,
  };
}

/**
 * Decide what text to persist for portal before/after view.
 * - retention none → no text
 * - storePrompts false → no text (privacy opt-out)
 * - otherwise clip to plan limits
 */
export function textsForStorage(opts: {
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  originalText: string;
  optimizedText: string;
}): StoredPromptTexts {
  if (opts.retentionPolicy === "none" || !opts.storePrompts) {
    return {
      originalText: null,
      optimizedText: null,
      originalTruncated: false,
      optimizedTruncated: false,
      promptPreview: null,
    };
  }

  const limits = getPlanLimits(opts.plan);
  const original = clip(opts.originalText, limits.originalChars);
  const optimized = clip(opts.optimizedText, limits.optimizedChars);
  const previewSource = opts.originalText || opts.optimizedText;
  const preview = previewSource.slice(0, 280);

  return {
    originalText: original.text || null,
    optimizedText: optimized.text || null,
    originalTruncated: original.truncated,
    optimizedTruncated: optimized.truncated,
    promptPreview: preview || null,
  };
}

export function planUpgradeHint(limits: PlanLimits): string | null {
  if (limits.id === "free") {
    return `Free plan shows up to ${limits.originalChars.toLocaleString()} characters per side. Upgrade to Pro for full before/after history.`;
  }
  if (limits.id === "pro") {
    return `Pro plan shows up to ${limits.originalChars.toLocaleString()} characters per side. Team plan stores more.`;
  }
  return null;
}
