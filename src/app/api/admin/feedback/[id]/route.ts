import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireAdmin } from "@/lib/auth";
import { prisma } from "@/lib/db";

type Ctx = { params: Promise<{ id: string }> };

const patchSchema = z.object({
  status: z.enum(["new", "read", "closed"]).optional(),
  adminNote: z.string().trim().max(2000).optional().nullable(),
});

export async function PATCH(req: NextRequest, ctx: Ctx) {
  try {
    await requireAdmin();
    const { id } = await ctx.params;
    const body = await req.json().catch(() => ({}));
    const parsed = patchSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid update" }, { status: 400 });
    }

    const data: {
      status?: string;
      adminNote?: string | null;
    } = {};
    if (parsed.data.status) data.status = parsed.data.status;
    if (parsed.data.adminNote !== undefined) {
      data.adminNote = parsed.data.adminNote || null;
    }

    const row = await prisma.feedbackSubmission.update({
      where: { id },
      data,
    });
    return NextResponse.json({ ok: true, feedback: row });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin feedback PATCH", err);
    return NextResponse.json(
      { error: "Failed to update feedback" },
      { status: 500 }
    );
  }
}

export async function DELETE(_req: NextRequest, ctx: Ctx) {
  try {
    await requireAdmin();
    const { id } = await ctx.params;
    await prisma.feedbackSubmission.delete({ where: { id } });
    return NextResponse.json({ ok: true });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin feedback DELETE", err);
    return NextResponse.json(
      { error: "Failed to delete feedback" },
      { status: 500 }
    );
  }
}
