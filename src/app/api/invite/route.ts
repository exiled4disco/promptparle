import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import {
  createInvitation,
  listInvitationsByUser,
} from "@/lib/invitations";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { isMailConfigured } from "@/lib/mail";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";

/**
 * User-facing invitations (0.32.0). Any signed-in user can invite a friend; the
 * invite email carries the link. Admins see every invite via /api/admin/invitations;
 * a user sees only their OWN here. Unlike the admin route, the raw invite URL is NOT
 * returned to the client — it goes out by email only.
 */
export async function GET() {
  try {
    const user = await requireUser();
    const rows = await listInvitationsByUser(user.id);
    return NextResponse.json({
      invitations: rows.map((r) => ({
        id: r.id,
        email: r.email,
        status: r.status,
        expiresAt: r.expiresAt,
        createdAt: r.createdAt,
        acceptedAt: r.acceptedAt,
        acceptedUser: r.acceptedUser
          ? { email: r.acceptedUser.email, name: r.acceptedUser.name }
          : null,
      })),
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("invite GET", err);
    return NextResponse.json({ error: "Failed to list invitations" }, { status: 500 });
  }
}

const postSchema = z.object({
  email: z.string().trim().email().max(255),
  note: z.string().max(500).optional().nullable(),
});

export async function POST(req: NextRequest) {
  try {
    const user = await requireUser();

    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `invite:user:${user.id}`,
      RL.inviteRequestIp.max,
      RL.inviteRequestIp.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    if (!isMailConfigured()) {
      return NextResponse.json(
        { error: "Email is not configured; cannot send invitations right now." },
        { status: 503 }
      );
    }

    const body = await req.json().catch(() => ({}));
    const parsed = postSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "A valid email is required." }, { status: 400 });
    }

    const result = await createInvitation({
      email: parsed.data.email,
      invitedById: user.id,
      note: parsed.data.note,
    });

    await writeAudit({
      action: "auth.register",
      userId: user.id,
      ip: ip !== "unknown" ? ip : null,
      meta: {
        kind: "invitation_created",
        by: "user",
        inviteId: result.invitation.id,
        email: result.invitation.email,
      },
    });

    // NOTE: raw inviteUrl intentionally NOT returned to non-admin users — the link
    // is delivered by email only.
    return NextResponse.json({
      ok: true,
      invitation: {
        id: result.invitation.id,
        email: result.invitation.email,
        status: result.invitation.status,
        expiresAt: result.invitation.expiresAt,
        createdAt: result.invitation.createdAt,
      },
      message: `Invitation sent to ${result.invitation.email}`,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    const msg = err instanceof Error ? err.message : "Failed to create invitation";
    console.error("invite POST", err);
    return NextResponse.json({ error: msg }, { status: 400 });
  }
}
