import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireAdmin } from "@/lib/auth";
import { prisma } from "@/lib/db";
import { replyToFeedback } from "@/lib/feedback";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

type Ctx = { params: Promise<{ id: string }> };

const patchSchema = z.object({
  status: z.enum(["new", "read", "closed"]).optional(),
  adminNote: z.string().trim().max(2000).optional().nullable(),
  /** When present, email this reply to the submitter (and log it). */
  reply: z.string().trim().min(1).max(8000).optional(),
  /** Close the message after replying (default true when replying). */
  close: z.boolean().optional(),
});

export async function PATCH(req: NextRequest, ctx: Ctx) {
  try {
    const admin = await requireAdmin();
    const { id } = await ctx.params;
    const body = await req.json().catch(() => ({}));
    const parsed = patchSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid update" }, { status: 400 });
    }

    // Reply path: email the submitter, append to the reply log, set status.
    if (parsed.data.reply) {
      const row = await replyToFeedback({
        id,
        reply: parsed.data.reply,
        adminName: admin.name || admin.email,
        close: parsed.data.close !== false,
      });
      await writeAudit({
        action: "contact.reply",
        userId: admin.id,
        ip: getClientIpFromHeaders(req.headers),
        meta: { feedbackId: id },
      });
      return NextResponse.json({ ok: true, feedback: row });
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
    const msg = err instanceof Error ? err.message : "Failed to update feedback";
    console.error("admin feedback PATCH", err);
    return NextResponse.json({ error: msg }, { status: 500 });
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
