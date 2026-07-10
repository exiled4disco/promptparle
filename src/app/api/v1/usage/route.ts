import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { getUsageSummary } from "@/lib/usage";

/**
 * Desktop / local-UI usage summary.
 * Query:
 *   recent=0     totals only (cheapest)
 *   recent=N     last N rows (default 5, max plan limit)
 * Never returns stored prompt bodies — portal page does that for edit/history.
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

    const summary = await getUsageSummary(auth.user.id, {
      plan: auth.user.plan,
      includeRecent,
      recentLimit,
      includeByProvider: true,
      includePromptBodies: false,
    });

    return NextResponse.json({
      request_count: summary.requestCount,
      original_tokens: summary.originalTokens,
      optimized_tokens: summary.optimizedTokens,
      tokens_saved: summary.tokensSaved,
      reduction_percent: summary.reductionPercent,
      plan: summary.plan,
      by_provider: summary.byProvider,
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
