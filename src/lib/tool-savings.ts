import { prisma } from "./db";
import { estimateSavingsUsd, tokensFromChars } from "./pricing";

/**
 * Per-tool token-savings bridge (server side).
 *
 * The desktop client is local-first: it calls AI providers directly and
 * computes token savings on the PC. This module accepts the aggregate,
 * privacy-safe rollup (counts + labels only, never prompt/context bodies)
 * and stores it in ToolSavingsDaily for portal display.
 */

/** Tools we accept. Unknown labels are dropped (never stored). */
export const TOOL_ALLOWLIST = [
  "fleet",
  "relevant_slice",
  "git",
  "ssh_read",
  "error_brief",
  "chat_memory",
  "budget_cap",
  "framing",
  "code_brief",
  "web_page",
  "quality_gate",
] as const;

export type ToolName = (typeof TOOL_ALLOWLIST)[number];

const TOOL_SET = new Set<string>(TOOL_ALLOWLIST);

/** Cap on distinct rows accepted per push (matches endpoint zod cap). */
export const MAX_SAVINGS_ITEMS = 40;

export type ToolSavingsItem = {
  tool: string;
  provider: string;
  charsSaved: number;
  occurrences: number;
};

function isValidDay(day: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(day);
}

function sanitizeItem(raw: ToolSavingsItem): ToolSavingsItem | null {
  const tool = String(raw.tool || "").trim().toLowerCase();
  if (!TOOL_SET.has(tool)) return null; // ignore unknown tools
  const provider = String(raw.provider || "").trim().toLowerCase().slice(0, 40);
  if (!provider) return null;
  const charsSaved = Math.max(0, Math.floor(Number(raw.charsSaved) || 0));
  const occurrences = Math.max(0, Math.floor(Number(raw.occurrences) || 0));
  if (charsSaved === 0 && occurrences === 0) return null;
  return { tool, provider, charsSaved, occurrences };
}

/**
 * Upsert-accumulate per-tool savings for a UTC day.
 * On conflict (same user/day/tool/provider) increments charsSaved + occurrences.
 * Returns number of rows written.
 */
export async function recordToolSavings(opts: {
  userId: string;
  day: string;
  items: ToolSavingsItem[];
}): Promise<{ stored: number }> {
  const { userId } = opts;
  const day = String(opts.day || "").trim();
  if (!isValidDay(day)) return { stored: 0 };

  const items = (opts.items || [])
    .slice(0, MAX_SAVINGS_ITEMS)
    .map(sanitizeItem)
    .filter((x): x is ToolSavingsItem => x !== null);

  if (items.length === 0) return { stored: 0 };

  // Merge duplicate (tool, provider) pairs within a single push before upsert.
  const merged = new Map<string, ToolSavingsItem>();
  for (const it of items) {
    const key = `${it.tool}::${it.provider}`;
    const prev = merged.get(key);
    if (prev) {
      prev.charsSaved += it.charsSaved;
      prev.occurrences += it.occurrences;
    } else {
      merged.set(key, { ...it });
    }
  }

  let stored = 0;
  for (const it of merged.values()) {
    await prisma.toolSavingsDaily.upsert({
      where: {
        userId_day_tool_provider: {
          userId,
          day,
          tool: it.tool,
          provider: it.provider,
        },
      },
      create: {
        userId,
        day,
        tool: it.tool,
        provider: it.provider,
        charsSaved: it.charsSaved,
        occurrences: it.occurrences,
      },
      update: {
        charsSaved: { increment: it.charsSaved },
        occurrences: { increment: it.occurrences },
      },
    });
    stored += 1;
  }

  return { stored };
}

export type ToolSavingsSummary = {
  sinceDays: number;
  totalCharsSaved: number;
  totalTokensSaved: number;
  totalOccurrences: number;
  byTool: Array<{
    tool: string;
    charsSaved: number;
    tokensSaved: number;
    occurrences: number;
  }>;
  byProvider: Array<{
    provider: string;
    charsSaved: number;
    tokensSaved: number;
    occurrences: number;
  }>;
};

/**
 * Aggregate rollup grouped by tool and by provider over the last `sinceDays`.
 * Mirrors the shape/style of getUsageSummary's by-provider rollup.
 */
export async function getToolSavingsSummary(
  userId: string,
  opts?: { sinceDays?: number }
): Promise<ToolSavingsSummary> {
  const sinceDays = Math.min(365, Math.max(1, opts?.sinceDays ?? 30));

  const cutoff = new Date();
  cutoff.setUTCDate(cutoff.getUTCDate() - (sinceDays - 1));
  const cutoffDay = cutoff.toISOString().slice(0, 10);

  const where = { userId, day: { gte: cutoffDay } };

  const [byTool, byProvider] = await Promise.all([
    prisma.toolSavingsDaily.groupBy({
      by: ["tool"],
      where,
      _sum: { charsSaved: true, occurrences: true },
    }),
    prisma.toolSavingsDaily.groupBy({
      by: ["provider"],
      where,
      _sum: { charsSaved: true, occurrences: true },
    }),
  ]);

  let totalCharsSaved = 0;
  let totalOccurrences = 0;

  const toolRows = byTool
    .map((r) => {
      const chars = r._sum.charsSaved ?? 0;
      const occ = r._sum.occurrences ?? 0;
      totalCharsSaved += chars;
      totalOccurrences += occ;
      return {
        tool: r.tool,
        charsSaved: chars,
        tokensSaved: tokensFromChars(chars),
        occurrences: occ,
      };
    })
    .sort((a, b) => b.charsSaved - a.charsSaved);

  const providerRows = byProvider
    .map((r) => {
      const chars = r._sum.charsSaved ?? 0;
      return {
        provider: r.provider,
        charsSaved: chars,
        tokensSaved: tokensFromChars(chars),
        occurrences: r._sum.occurrences ?? 0,
      };
    })
    .sort((a, b) => b.charsSaved - a.charsSaved);

  return {
    sinceDays,
    totalCharsSaved,
    totalTokensSaved: tokensFromChars(totalCharsSaved),
    totalOccurrences,
    byTool: toolRows,
    byProvider: providerRows,
  };
}

/** Convenience: blended USD estimate for a total tokens-saved count + model. */
export function toolSavingsUsd(tokensSaved: number, model: string): number {
  return estimateSavingsUsd(tokensSaved, model);
}
