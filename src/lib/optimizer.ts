import type { OptimizationProfileId } from "./constants";
import { estimateTokens } from "./tokens";
import { maskSecrets } from "./secrets";
import { runContextFleet } from "./context-fleet";
import { buildImageSignal } from "./image-signal";
import type { AdapterImage } from "./adapters/types";
import {
  normalizeCompressionLevel,
  type CompressionLevel,
} from "./compression-level";

export type OptimizeInput = {
  prompt: string;
  context?: string;
  profile?: OptimizationProfileId | string;
  /** soft cap for optimized output tokens (estimate) */
  maxTokens?: number;
  /** Vision images — binary still forwarded separately; we add a focus brief */
  images?: AdapterImage[];
  /** 1 max fidelity … 5 max savings (default 3 balanced) */
  compressionLevel?: CompressionLevel | number;
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
  /** e.g. signal-brief-hybrid | code-brief | sheet-card | fleet | log-dedupe */
  strategy?: string;
  /** optional structured impress stats for UI */
  signals?: Record<string, number | string | boolean>;
  compressionLevel?: CompressionLevel;
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
  notes: string[],
  extra?: {
    strategy?: string;
    signals?: OptimizeResult["signals"];
    compressionLevel?: CompressionLevel;
  }
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
    strategy: extra?.strategy,
    signals: extra?.signals,
    compressionLevel: extra?.compressionLevel,
  };
}

/**
 * Context optimizer — modality fleet:
 *  - Documents → SIGNAL BRIEF (hybrid)
 *  - Code → CODE BRIEF (signatures + query-deep bodies)
 *  - Sheets → SHEET CARD (schema + stats + samples)
 *  - Logs → dedupe
 *  - Images → IMAGE SIGNAL focus brief (pixels still go multimodal)
 */
export function optimizePrompt(input: OptimizeInput): OptimizeResult {
  const profile = input.profile || "general";
  const compressionLevel = normalizeCompressionLevel(input.compressionLevel);
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

  // 3) Context fleet (docs / code / sheets / logs / multi-file)
  let strategy = "lean";
  let signals: OptimizeResult["signals"] | undefined;

  if (context) {
    const fleet = runContextFleet(context, {
      prompt,
      profile,
      compressionLevel,
    });
    if (fleet.applied) {
      context = fleet.text;
      notes.push(...fleet.notes);
      strategy = fleet.strategy || "fleet";
      signals = { ...fleet.signals, dial: compressionLevel };
    } else if (fleet.notes.length) {
      notes.push(...fleet.notes);
    }
  }

  // 4) Image focus brief (text channel) — binaries forwarded separately
  if (input.images && input.images.length > 0) {
    const img = buildImageSignal(input.images, { prompt, profile });
    if (img.applied && img.text) {
      // Prepend image signal to context so vision + text share one plan
      context = context ? `${img.text}\n\n${context}` : img.text;
      notes.push(...img.notes);
      signals = {
        ...(signals || {}),
        ...img.stats,
        imageStrategy: img.strategy,
      };
      if (strategy === "lean" || strategy === "passthrough") {
        strategy = "image-signal";
      } else if (!String(strategy).includes("image")) {
        strategy = `fleet+image`;
      }
    }
  }

  // 5) Lean payload
  let optimized = buildPayload(prompt, context);

  // 6) Token budget
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
    notes,
    { strategy, signals, compressionLevel }
  );

  // 7) NEVER expand vs the user's original input
  // Note: image brief can add text while images aren't in originalTokens —
  // allow small growth only when images are present, else pass-through.
  const imageSlack =
    input.images && input.images.length > 0
      ? Math.min(400, 80 * input.images.length + 120)
      : 0;

  if (result.expanded && result.optimizedTokens > originalTokens + imageSlack) {
    const passthrough = truncateToTokenBudget(
      collapseBlankLines(
        [promptScan.text, contextScan.text].filter(Boolean).join("\n\n")
      ),
      maxTokens
    );
    // If we have images, still attach a minimal one-line focus so vision isn't blind
    let ptText = passthrough;
    let ptNotes = notes.length
      ? [...notes, "Used pass-through to avoid expansion"]
      : ["Pass-through (no safe reduction without growing the payload)"];
    if (input.images && input.images.length > 0) {
      const mini = `Images attached: ${input.images.length}. Prefer OCR of text/errors/tables in images.`;
      ptText = `${passthrough}\n\n${mini}`;
      ptNotes = [...ptNotes, "Kept minimal image focus line"];
    }
    const pt = finalizeStats(
      ptText,
      originalTokens,
      profile,
      secretFindings,
      ptNotes,
      {
        strategy: strategy === "lean" ? "passthrough" : strategy,
        signals,
        compressionLevel,
      }
    );
    if (pt.optimizedTokens <= result.optimizedTokens) {
      result = pt;
    }
  }

  if (result.expanded && result.optimizedTokens > originalTokens + imageSlack) {
    const safe = truncateToTokenBudget(rawCombined.trim(), maxTokens);
    result = finalizeStats(
      safe,
      originalTokens,
      profile,
      secretFindings,
      [...notes, "Pass-through original (optimizer refused to expand)"],
      { strategy: "passthrough", compressionLevel }
    );
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

  // Image brief added intentional tokens — don't flag as bug expansion
  if (
    imageSlack > 0 &&
    result.expanded &&
    result.optimizedTokens <= originalTokens + imageSlack
  ) {
    result = {
      ...result,
      expanded: false,
      reductionPercent: Math.max(
        0,
        Math.round(
          ((originalTokens - result.optimizedTokens) / Math.max(1, originalTokens)) *
            100
        )
      ),
    };
  }

  return result;
}
