import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { getUsageSummary } from "@/lib/usage";

export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const summary = await getUsageSummary(auth.user.id);
    return NextResponse.json({
      request_count: summary.requestCount,
      original_tokens: summary.originalTokens,
      optimized_tokens: summary.optimizedTokens,
      tokens_saved: summary.tokensSaved,
      reduction_percent: summary.reductionPercent,
      recent: summary.recent.map((r) => ({
        id: r.id,
        provider: r.provider,
        model: r.model,
        optimization_profile: r.optimizationProfile,
        original_tokens: r.originalTokens,
        optimized_tokens: r.optimizedTokens,
        status: r.status,
        created_at: r.createdAt,
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
