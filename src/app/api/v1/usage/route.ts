import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { getUsageSummary } from "@/lib/usage";
import { getToolSavingsSummary } from "@/lib/tool-savings";

/**
 * Desktop / local-UI usage summary.
 * Query:
 *   recent=0     totals only (cheapest)
 *   recent=N     last N rows (default 5, max plan limit)
 * Never returns stored prompt bodies. portal page does that for edit/history.
 */
export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const recentParam = req.nextUrl.searchParams.get("recent");
    let includeRecent = true;
    let recentLimit = 5;
    if (recentParam === "0" || recentParam === "false") {
      includeRecent = false;
      recentLimit = 0;
    } else if (recentParam && /^\d+$/.test(recentParam)) {
      recentLimit = Math.min(50, parseInt(recentParam, 10));
    }

    // Opt-in per-tool savings rollup (?include=tools). Additive, does not
    // change the existing response shape.
    const include = (req.nextUrl.searchParams.get("include") || "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean);
    const includeTools = include.includes("tools");
    const sinceParam = req.nextUrl.searchParams.get("since_days");
    const sinceDays =
      sinceParam && /^\d+$/.test(sinceParam)
        ? Math.min(365, Math.max(1, parseInt(sinceParam, 10)))
        : 30;

    const [summary, toolSavings] = await Promise.all([
      getUsageSummary(auth.user.id, {
        plan: auth.user.plan,
        includeRecent,
        recentLimit,
        includeByProvider: true,
        includePromptBodies: false,
      }),
      includeTools
        ? getToolSavingsSummary(auth.user.id, { sinceDays })
        : Promise.resolve(null),
    ]);

    return NextResponse.json({
      request_count: summary.requestCount,
      original_tokens: summary.originalTokens,
      optimized_tokens: summary.optimizedTokens,
      tokens_saved: summary.tokensSaved,
      reduction_percent: summary.reductionPercent,
      plan: summary.plan,
      by_provider: summary.byProvider,
      ...(toolSavings
        ? {
            by_tool: {
              since_days: toolSavings.sinceDays,
              total_chars_saved: toolSavings.totalCharsSaved,
              total_tokens_saved: toolSavings.totalTokensSaved,
              total_occurrences: toolSavings.totalOccurrences,
              tools: toolSavings.byTool.map((t) => ({
                tool: t.tool,
                chars_saved: t.charsSaved,
                tokens_saved: t.tokensSaved,
                occurrences: t.occurrences,
              })),
              providers: toolSavings.byProvider.map((p) => ({
                provider: p.provider,
                chars_saved: p.charsSaved,
                tokens_saved: p.tokensSaved,
                occurrences: p.occurrences,
              })),
            },
          }
        : {}),
      recent: summary.recent.map((r) => ({
        id: r.id,
        provider: r.provider,
        model: r.model,
        optimization_profile: r.optimizationProfile,
        original_tokens: r.originalTokens,
        optimized_tokens: r.optimizedTokens,
        reduction_percent: r.reductionPercent,
        status: r.status,
        created_at: r.createdAt,
        prompt_preview: r.promptPreview,
      })),
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/usage error", err);
    return NextResponse.json({ error: "Failed to load usage" }, { status: 500 });
  }
}
