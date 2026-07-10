import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { prisma } from "@/lib/db";
import { getUsageSummary } from "@/lib/usage";

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
 * DELETE /api/usage?all=1 — clear entire request history for the signed-in user.
 * Stats on the page recompute from remaining rows (none after clear).
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

    const result = await prisma.promptRequest.deleteMany({
      where: { userId: user.id },
    });

    return NextResponse.json({ ok: true, deleted: result.count });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("usage DELETE all", err);
    return NextResponse.json({ error: "Failed to clear history" }, { status: 500 });
  }
}
