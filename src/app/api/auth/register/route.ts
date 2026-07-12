import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { hashPassword, setSessionCookie, createSession } from "@/lib/auth";
import { createAndSendVerification } from "@/lib/email-verification";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

/**
 * Self-serve registration (0.32.0 — PromptParle is free and open; no invitation
 * required). Creates an unverified account and emails a verification link. The
 * account can sign in but the app gates on emailVerifiedAt until it's confirmed.
 * Invitations still exist (users can invite others) but are no longer a gate.
 */
const schema = z.object({
  name: z.string().trim().max(120).optional().nullable(),
  email: z.string().trim().email().max(200),
  password: z.string().min(8).max(128),
});

export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `register:ip:${ip}`,
      RL.registerIp.max,
      RL.registerIp.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "A valid email and a password of at least 8 characters are required." },
        { status: 400 }
      );
    }

    const email = parsed.data.email.toLowerCase();
    const name = parsed.data.name?.trim() || null;

    const existing = await prisma.user.findUnique({ where: { email } });
    if (existing) {
      // Don't leak whether a verified account exists beyond what the client needs
      // to route the user. An unverified account can just re-verify.
      if (!existing.emailVerifiedAt) {
        try {
          await createAndSendVerification({
            id: existing.id,
            email: existing.email,
            name: existing.name,
          });
        } catch (e) {
          console.error("register: resend verification failed", e);
        }
        return NextResponse.json(
          {
            error: "An account with this email is awaiting verification. We re-sent the link.",
            code: "exists_unverified",
            email,
          },
          { status: 409 }
        );
      }
      return NextResponse.json(
        {
          error: "An account already exists for this email. Sign in instead.",
          code: "exists",
        },
        { status: 409 }
      );
    }

    const passwordHash = await hashPassword(parsed.data.password);
    const user = await prisma.user.create({
      data: {
        email,
        name,
        passwordHash,
        plan: "free",
        emailVerifiedAt: null, // self-serve must verify by email
      },
    });

    try {
      await createAndSendVerification({
        id: user.id,
        email: user.email,
        name: user.name,
      });
    } catch (e) {
      console.error("register: send verification failed", e);
    }

    // Sign them in so the verify-email step is seamless; the app layout still
    // redirects to /verify-email until emailVerifiedAt is set.
    const sessionToken = await createSession(user.id);
    await setSessionCookie(sessionToken);

    await writeAudit({
      action: "auth.register",
      userId: user.id,
      ip,
      meta: { method: "self_serve" },
    });

    return NextResponse.json({
      ok: true,
      email,
      message:
        "Account created. Check your email for a verification link to finish setting up.",
    });
  } catch (err) {
    console.error("register", err);
    return NextResponse.json(
      { error: "Could not create your account. Please try again." },
      { status: 500 }
    );
  }
}
