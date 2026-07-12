import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { getUsageSummary } from "@/lib/usage";
import { getToolSavingsSummary } from "@/lib/tool-savings";
import { hideUsageHistoryRows } from "@/lib/usage-history";

export async function GET(req: NextRequest) {
  try {
    const user = await requireUser();
    // Portal session API may include stored prompt bodies for history compare UI.
    const summary = await getUsageSummary(user.id, {
      includePromptBodies: true,
    });

    // Opt-in per-tool savings rollup (?include=tools). Additive: existing
    // response shape is unchanged when the param is absent.
    const include = (req.nextUrl.searchParams.get("include") || "")
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean);
    if (include.includes("tools")) {
      const sinceParam = req.nextUrl.searchParams.get("since_days");
      const sinceDays =
        sinceParam && /^\d+$/.test(sinceParam)
          ? Math.min(365, Math.max(1, parseInt(sinceParam, 10)))
          : 30;
      const toolSavings = await getToolSavingsSummary(user.id, { sinceDays });
      return NextResponse.json({
        ...summary,
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
      });
    }

    return NextResponse.json(summary);
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("usage GET", err);
    return NextResponse.json({ error: "Failed to load usage" }, { status: 500 });
  }
}

/**
 * DELETE /api/usage?all=1. clear Request History for the signed-in user.
 * Soft-hide only: token totals / request counts / by-provider stats stay.
 */
export async function DELETE(req: NextRequest) {
  try {
    const user = await requireUser();
    const all =
      req.nextUrl.searchParams.get("all") === "1" ||
      req.nextUrl.searchParams.get("all") === "true";

    if (!all) {
      return NextResponse.json(
        {
          error:
            "To clear all request history, call DELETE /api/usage?all=1. To delete one row, use DELETE /api/usage/{id}.",
        },
        { status: 400 }
      );
    }

    const result = await hideUsageHistoryRows({ userId: user.id, all: true });

    return NextResponse.json({
      ok: true,
      deleted: result.hidden,
      statsPreserved: true,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("usage DELETE all", err);
    return NextResponse.json({ error: "Failed to clear history" }, { status: 500 });
  }
}
