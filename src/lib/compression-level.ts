/**
 * Compression dial 1-5. orthogonal to optimization profile.
 * Profile = domain (docs, security, logs). Dial = how hard to compress.
 */

export type CompressionLevel = 1 | 2 | 3 | 4 | 5;

export type CompressionAggressiveness = {
  mode: "hybrid" | "brief" | "light";
  maxObligations: number;
  maxEvidence: number;
  maxNumbers: number;
  evidenceSentences: number;
  deepKeepSections: number;
  leadAllSections: boolean;
  keepCode: boolean;
  /** soft char budget as fraction of cleaned context */
  targetRatio: number;
  /** code keep ratio */
  codeTargetRatio: number;
  /** sheet sample row budget */
  sheetSampleRows: number;
  /** aggressive log line dedupe */
  aggressiveLogDedupe: boolean;
};

export const COMPRESSION_LEVELS = [
  {
    id: 1 as const,
    key: "max-fidelity",
    label: "Max fidelity",
    short: "Near-full text",
    hint: "~0-15% fewer tokens",
  },
  {
    id: 2 as const,
    key: "high-fidelity",
    label: "High fidelity",
    short: "Coverage + deep keep",
    hint: "~25-40% fewer",
  },
  {
    id: 3 as const,
    key: "balanced",
    label: "Balanced",
    short: "Strong savings, solid coverage",
    hint: "~45-60% fewer",
  },
  {
    id: 4 as const,
    key: "high-savings",
    label: "High savings",
    short: "Map + obligations",
    hint: "~70-85% fewer",
  },
  {
    id: 5 as const,
    key: "max-savings",
    label: "Max savings",
    short: "Executive crush",
    hint: "~85%+ fewer",
  },
] as const;

export const DEFAULT_COMPRESSION_LEVEL: CompressionLevel = 3;

const LEVEL_BASE: Record<CompressionLevel, CompressionAggressiveness> = {
  1: {
    mode: "light",
    maxObligations: 28,
    maxEvidence: 14,
    maxNumbers: 24,
    evidenceSentences: 4,
    deepKeepSections: 12,
    leadAllSections: true,
    keepCode: true,
    targetRatio: 0.9,
    codeTargetRatio: 0.88,
    sheetSampleRows: 24,
    aggressiveLogDedupe: false,
  },
  2: {
    mode: "hybrid",
    maxObligations: 22,
    maxEvidence: 10,
    maxNumbers: 18,
    evidenceSentences: 3,
    deepKeepSections: 5,
    leadAllSections: true,
    keepCode: true,
    targetRatio: 0.55,
    codeTargetRatio: 0.55,
    sheetSampleRows: 16,
    aggressiveLogDedupe: false,
  },
  3: {
    mode: "hybrid",
    maxObligations: 18,
    maxEvidence: 8,
    maxNumbers: 16,
    evidenceSentences: 2,
    deepKeepSections: 3,
    leadAllSections: true,
    keepCode: true,
    targetRatio: 0.38,
    codeTargetRatio: 0.4,
    sheetSampleRows: 12,
    aggressiveLogDedupe: false,
  },
  4: {
    mode: "brief",
    maxObligations: 14,
    maxEvidence: 6,
    maxNumbers: 14,
    evidenceSentences: 1,
    deepKeepSections: 1,
    leadAllSections: false,
    keepCode: true,
    targetRatio: 0.22,
    codeTargetRatio: 0.28,
    sheetSampleRows: 8,
    aggressiveLogDedupe: true,
  },
  5: {
    mode: "brief",
    maxObligations: 10,
    maxEvidence: 4,
    maxNumbers: 10,
    evidenceSentences: 1,
    deepKeepSections: 0,
    leadAllSections: false,
    keepCode: false,
    targetRatio: 0.14,
    codeTargetRatio: 0.18,
    sheetSampleRows: 5,
    aggressiveLogDedupe: true,
  },
};

/** Clamp unknown input to 1-5 (default balanced). */
export function normalizeCompressionLevel(value: unknown): CompressionLevel {
  const n = typeof value === "string" ? parseInt(value, 10) : Number(value);
  if (n === 1 || n === 2 || n === 3 || n === 4 || n === 5) return n;
  return DEFAULT_COMPRESSION_LEVEL;
}

export function compressionLevelMeta(level: CompressionLevel) {
  return COMPRESSION_LEVELS.find((l) => l.id === level) || COMPRESSION_LEVELS[2];
}

/**
 * Resolve dial + profile into compressor budgets.
 * Dial owns intensity; profile nudges domain priorities.
 */
export function aggressivenessFor(
  level: CompressionLevel | number | string | undefined,
  profile = "general"
): CompressionAggressiveness {
  const dial = normalizeCompressionLevel(level);
  const base = {...LEVEL_BASE[dial] };
  const p = (profile || "general").toLowerCase();

  // Domain nudges (do not override dial direction)
  if (p === "security-review") {
    base.maxObligations = Math.min(30, base.maxObligations + 4);
    base.maxNumbers = Math.min(28, base.maxNumbers + 4);
    base.keepCode = true;
  } else if (p === "documentation") {
    base.leadAllSections = dial <= 3 ? true : base.leadAllSections;
    base.deepKeepSections = Math.min(12, base.deepKeepSections + (dial <= 2 ? 1 : 0));
  } else if (p === "executive-summary") {
    // profile hints more savings; dial still wins floor
    if (dial >= 3) {
      base.targetRatio = Math.min(base.targetRatio, 0.28);
      base.mode = dial >= 4 ? "brief" : base.mode;
    }
  } else if (p === "log-analysis") {
    base.aggressiveLogDedupe = dial >= 2;
  } else if (p === "developer") {
    base.keepCode = true;
    base.codeTargetRatio = Math.min(0.95, base.codeTargetRatio + 0.06);
  }

  return base;
}
