import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import {
  AuthError,
  destroyAllSessionsForUser,
  requireAdmin,
} from "@/lib/auth";
import { prisma } from "@/lib/db";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

type Ctx = { params: Promise<{ id: string }> };

const patchSchema = z.object({
  action: z.enum(["disable", "enable"]),
  reason: z.string().trim().max(500).optional().nullable(),
});

async function countOtherAdmins(excludeUserId: string): Promise<number> {
  return prisma.user.count({
    where: {
      isAdmin: true,
      disabledAt: null,
      id: { not: excludeUserId },
    },
  });
}

/**
 * Admin: disable or re-enable a registered account.
 * Disable clears browser sessions; API keys fail auth while disabled.
 */
export async function PATCH(req: NextRequest, ctx: Ctx) {
  try {
    const admin = await requireAdmin();
    const { id } = await ctx.params;
    const body = await req.json().catch(() => ({}));
    const parsed = patchSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "action must be disable or enable" },
        { status: 400 }
      );
    }

    const target = await prisma.user.findUnique({
      where: { id },
      select: {
        id: true,
        email: true,
        isAdmin: true,
        disabledAt: true,
      },
    });
    if (!target) {
      return NextResponse.json({ error: "User not found" }, { status: 404 });
    }

    if (target.id === admin.id) {
      return NextResponse.json(
        { error: "You cannot disable or re-enable your own account here." },
        { status: 400 }
      );
    }

    if (parsed.data.action === "disable") {
      if (target.isAdmin) {
        const others = await countOtherAdmins(target.id);
        if (others < 1) {
          return NextResponse.json(
            { error: "Cannot disable the last active admin account." },
            { status: 400 }
          );
        }
      }

      const updated = await prisma.user.update({
        where: { id },
        data: {
          disabledAt: new Date(),
          disabledReason: (parsed.data.reason || "").trim() || null,
        },
        select: {
          id: true,
          email: true,
          disabledAt: true,
          disabledReason: true,
        },
      });
      await destroyAllSessionsForUser(id);
      await writeAudit({
        action: "admin.user_disable",
        userId: admin.id,
        ip: getClientIpFromHeaders(req.headers),
        meta: {
          targetUserId: id,
          targetEmail: target.email,
          reason: updated.disabledReason || undefined,
        },
      });
      return NextResponse.json({
        ok: true,
        user: updated,
        message: `Disabled ${target.email}`,
      });
    }

    // enable
    const updated = await prisma.user.update({
      where: { id },
      data: {
        disabledAt: null,
        disabledReason: null,
      },
      select: {
        id: true,
        email: true,
        disabledAt: true,
        disabledReason: true,
      },
    });
    await writeAudit({
      action: "admin.user_enable",
      userId: admin.id,
      ip: getClientIpFromHeaders(req.headers),
      meta: { targetUserId: id, targetEmail: target.email },
    });
    return NextResponse.json({
      ok: true,
      user: updated,
      message: `Re-enabled ${target.email}`,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin users PATCH", err);
    return NextResponse.json(
      { error: "Failed to update account" },
      { status: 500 }
    );
  }
}

/**
 * Admin: permanently delete a registered account and cascaded data.
 */
export async function DELETE(req: NextRequest, ctx: Ctx) {
  try {
    const admin = await requireAdmin();
    const { id } = await ctx.params;

    const target = await prisma.user.findUnique({
      where: { id },
      select: { id: true, email: true, isAdmin: true },
    });
    if (!target) {
      return NextResponse.json({ error: "User not found" }, { status: 404 });
    }

    if (target.id === admin.id) {
      return NextResponse.json(
        { error: "You cannot delete your own account." },
        { status: 400 }
      );
    }

    if (target.isAdmin) {
      const others = await countOtherAdmins(target.id);
      if (others < 1) {
        return NextResponse.json(
          { error: "Cannot delete the last active admin account." },
          { status: 400 }
        );
      }
    }

    await prisma.user.delete({ where: { id } });
    await writeAudit({
      action: "admin.user_delete",
      userId: admin.id,
      ip: getClientIpFromHeaders(req.headers),
      meta: { targetUserId: id, targetEmail: target.email },
    });

    return NextResponse.json({
      ok: true,
      message: `Deleted ${target.email}`,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin users DELETE", err);
    return NextResponse.json(
      { error: "Failed to delete account" },
      { status: 500 }
    );
  }
}
