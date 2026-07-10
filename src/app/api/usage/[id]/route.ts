import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { prisma } from "@/lib/db";

/**
 * DELETE /api/usage/[id] — remove one request-history row for the signed-in user.
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

    const result = await prisma.promptRequest.deleteMany({
      where: { id, userId: user.id },
    });

    if (result.count === 0) {
      return NextResponse.json({ error: "Not found" }, { status: 404 });
    }

    return NextResponse.json({ ok: true, deleted: 1, id });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("usage DELETE id", err);
    return NextResponse.json({ error: "Failed to delete" }, { status: 500 });
  }
}
