import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { isMailConfigured, sendInviteRequestEmail } from "@/lib/mail";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

const schema = z.object({
  name: z.string().trim().min(1).max(120),
  email: z.string().email().max(255),
  company: z.string().trim().max(160).optional().nullable(),
  note: z.string().trim().max(1000).optional().nullable(),
  /** Honeypot: bots fill this; humans leave it empty. */
  website: z.string().max(200).optional().nullable(),
});

/**
 * Who receives public invitation requests.
 * Always includes admin account emails from the DB, plus INVITE_REQUEST_TO /
 * ADMIN_EMAIL if set. Never depends on env alone (so your portal admin account
 * always gets the notice).
 */
async function resolveInviteRequestRecipients(): Promise<string[]> {
  const fromEnv = [
    ...(process.env.INVITE_REQUEST_TO || "").split(","),
    ...(process.env.ADMIN_EMAIL || "").split(","),
  ]
    .map((s) => s.trim().toLowerCase())
    .filter((s) => s.includes("@"));

  const admins = await prisma.user.findMany({
    where: { isAdmin: true },
    select: { email: true },
    take: 50,
  });
  const fromAdmins = admins
    .map((a) => (a.email || "").trim().toLowerCase())
    .filter((s) => s.includes("@"));

  return [...new Set([...fromEnv, ...fromAdmins])];
}

/**
 * Public: request an invitation (not account creation).
 * Emails admins; they send a real invite from /app/invitations.
 */
export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rlIp = checkRateLimit(
      `invite-req:ip:${ip}`,
      RL.inviteRequestIp.max,
      RL.inviteRequestIp.windowMs
    );
    if (!rlIp.ok) {
      const r = rateLimitResponse(rlIp.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Name and a valid email are required." },
        { status: 400 }
      );
    }

    // Silent success for honeypot fills
    if ((parsed.data.website || "").trim()) {
      return NextResponse.json({
        ok: true,
        message: "Thanks. We received your request.",
      });
    }

    const email = parsed.data.email.toLowerCase().trim();
    const name = parsed.data.name.trim();
    const company = (parsed.data.company || "").trim() || null;
    const note = (parsed.data.note || "").trim() || null;

    const rlEmail = checkRateLimit(
      `invite-req:email:${email}`,
      RL.inviteRequestEmail.max,
      RL.inviteRequestEmail.windowMs
    );
    if (!rlEmail.ok) {
      return NextResponse.json({
        ok: true,
        message:
          "Thanks. If we can invite you, we will email that address soon.",
      });
    }

    if (!isMailConfigured()) {
      return NextResponse.json(
        {
          error:
            "Invitation requests are temporarily unavailable. Try again later.",
        },
        { status: 503 }
      );
    }

    const recipients = await resolveInviteRequestRecipients();
    if (recipients.length === 0) {
      console.error(
        "invite request: no recipients (set INVITE_REQUEST_TO or create an isAdmin user)"
      );
      return NextResponse.json(
        {
          error:
            "Invitation requests are temporarily unavailable. Try again later.",
        },
        { status: 503 }
      );
    }

    try {
      await sendInviteRequestEmail({
        to: recipients,
        name,
        email,
        company,
        note,
        ip,
      });
      console.info(
        `invite request from ${email} notified: ${recipients.join(", ")}`
      );
    } catch (err) {
      console.error("invite request send failed", err);
      return NextResponse.json(
        { error: "Could not send your request. Try again later." },
        { status: 502 }
      );
    }

    await writeAudit({
      action: "auth.invite_request",
      ip,
      meta: {
        email,
        name,
        company: company || undefined,
        notified: recipients,
      },
    });

    return NextResponse.json({
      ok: true,
      message:
        "Thanks. We received your request. If approved, you will get an invitation code by email.",
    });
  } catch (err) {
    console.error("invite request error", err);
    return NextResponse.json({ error: "Request failed" }, { status: 500 });
  }
}
