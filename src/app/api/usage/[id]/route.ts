import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { hideUsageHistoryRows } from "@/lib/usage-history";

/**
 * DELETE /api/usage/[id]
 * Soft-hide one request from Request History.
 * Token stats (aggregates) are preserved.
 */
export async function DELETE(
  _req: NextRequest,
  ctx: { params: Promise<{ id: string }> }
) {
  try {
    const user = await requireUser();
    const { id } = await ctx.params;
    if (!id || id.length > 64) {
      return NextResponse.json({ error: "Invalid id" }, { status: 400 });
    }

    const result = await hideUsageHistoryRows({ userId: user.id, id });

    if (result.hidden === 0) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    return NextResponse.json({
      ok: true,
      deleted: 1,
      id,
      statsPreserved: true,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("usage DELETE id", err);
    return NextResponse.json({ error: "Failed to delete" }, { status: 500 });
  }
}
