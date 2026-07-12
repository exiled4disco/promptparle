import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { getUsageSummary } from "@/lib/usage";
import { hideUsageHistoryRows } from "@/lib/usage-history";

export async function GET() {
  try {
    const user = await requireUser();
    // Portal session API may include stored prompt bodies for history compare UI.
    const summary = await getUsageSummary(user.id, {
      includePromptBodies: true,
    });
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
