import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireAdmin } from "@/lib/auth";
import { createInvitation, listInvitations } from "@/lib/invitations";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { isMailConfigured } from "@/lib/mail";

export async function GET() {
  try {
    await requireAdmin();
    const rows = await listInvitations();
    return NextResponse.json({
      invitations: rows.map((r) => ({
        id: r.id,
        email: r.email,
        code: r.code,
        status: r.status,
        note: r.note,
        expiresAt: r.expiresAt,
        createdAt: r.createdAt,
        acceptedAt: r.acceptedAt,
        redeemedAt: r.redeemedAt,
        invitedBy: r.invitedBy.email,
        acceptedUser: r.acceptedUser
          ? { id: r.acceptedUser.id, email: r.acceptedUser.email, name: r.acceptedUser.name }
          : null,
      })),
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin invitations GET", err);
    return NextResponse.json({ error: "Failed to list invitations" }, { status: 500 });
  }
}

const postSchema = z.object({
  email: z.string().email().max(255),
  note: z.string().max(500).optional().nullable(),
});

export async function POST(req: NextRequest) {
  try {
    const admin = await requireAdmin();
    if (!isMailConfigured()) {
      return NextResponse.json(
        { error: "Email is not configured; cannot send invitations." },
        { status: 503 }
      );
    }

    const body = await req.json();
    const parsed = postSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Valid email required" }, { status: 400 });
    }

    const result = await createInvitation({
      email: parsed.data.email,
      invitedById: admin.id,
      note: parsed.data.note,
    });

    await writeAudit({
      action: "auth.register",
      userId: admin.id,
      ip: getClientIpFromHeaders(req.headers),
      meta: {
        kind: "invitation_created",
        inviteId: result.invitation.id,
        email: result.invitation.email,
      },
    });

    return NextResponse.json({
      ok: true,
      invitation: result.invitation,
      // Admin may copy link if email delayed (token only returned once at create)
      inviteUrl: result.inviteUrl,
      message: `Invitation sent to ${result.invitation.email}`,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    const msg = err instanceof Error ? err.message : "Failed to create invitation";
    console.error("admin invitations POST", err);
    return NextResponse.json({ error: msg }, { status: 400 });
  }
}
