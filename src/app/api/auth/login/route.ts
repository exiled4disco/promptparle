import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import {
  createSession,
  setSessionCookie,
  verifyPassword,
} from "@/lib/auth";
import {
  clearLoginFailures,
  getLoginLockout,
  recordLoginFailure,
} from "@/lib/login-lockout";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

const schema = z.object({
  email: z.string().email(),
  password: z.string().min(1).max(128),
});

export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rlIp = checkRateLimit(
      `login:ip:${ip}`,
      RL.loginIp.max,
      RL.loginIp.windowMs
    );
    if (!rlIp.ok) {
      const r = rateLimitResponse(
        rlIp.retryAfterSec,
        "Too many sign-in attempts from this network. Try again later."
      );
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid credentials" }, { status: 400 });
    }

    const email = parsed.data.email.toLowerCase().trim();
    const rlEmail = checkRateLimit(
      `login:email:${email}`,
      RL.loginEmail.max,
      RL.loginEmail.windowMs
    );
    if (!rlEmail.ok) {
      const r = rateLimitResponse(rlEmail.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const lock = await getLoginLockout(email);
    if (lock.locked) {
      await writeAudit({
        action: "auth.lockout",
        ip,
        meta: { email, remainingSec: lock.remainingSec },
      });
      return NextResponse.json(
        {
          error: `Account temporarily locked after failed sign-ins. Try again in ${Math.ceil(lock.remainingSec / 60)} minute(s).`,
          code: "locked",
          retry_after: lock.remainingSec,
        },
        {
          status: 429,
          headers: { "Retry-After": String(lock.remainingSec) },
        }
      );
    }

    const user = await prisma.user.findUnique({ where: { email } });
    if (!user || !user.passwordHash) {
      await recordLoginFailure(email);
      await writeAudit({
        action: "auth.login_failed",
        ip,
        meta: { email, reason: user ? "oauth_only" : "unknown" },
      });
      const hint = user && !user.passwordHash
        ? "This account uses Google or GitHub sign-in. Use the button above, or set a password later from Settings."
        : "Invalid email or password";
      return NextResponse.json(
        { error: user && !user.passwordHash ? hint : "Invalid email or password" },
        { status: 401 }
      );
    }

    const ok = await verifyPassword(parsed.data.password, user.passwordHash);
    if (!ok) {
      const after = await recordLoginFailure(email);
      await writeAudit({
        action: "auth.login_failed",
        userId: user.id,
        ip,
        meta: { fails: after.fails },
      });
      if (after.locked) {
        return NextResponse.json(
          {
            error: `Too many failed attempts. Account locked for ${Math.ceil(after.remainingSec / 60)} minute(s).`,
            code: "locked",
            retry_after: after.remainingSec,
          },
          {
            status: 429,
            headers: { "Retry-After": String(after.remainingSec) },
          }
        );
      }
      return NextResponse.json(
        { error: "Invalid email or password" },
        { status: 401 }
      );
    }

    if (!user.emailVerifiedAt) {
      return NextResponse.json(
        {
          error:
            "Please verify your email before signing in. Check your inbox for the link, or resend it.",
          code: "email_unverified",
          email: user.email,
        },
        { status: 403 }
      );
    }

    if (user.disabledAt) {
      await writeAudit({
        action: "auth.login_failed",
        userId: user.id,
        ip,
        meta: { reason: "disabled" },
      });
      return NextResponse.json(
        {
          error:
            "This account has been disabled. Contact support if you believe this is a mistake.",
          code: "account_disabled",
        },
        { status: 403 }
      );
    }

    await clearLoginFailures(email);
    const token = await createSession(user.id, {
      userAgent: req.headers.get("user-agent") || undefined,
      ipAddress: ip !== "unknown" ? ip : undefined,
      headers: req.headers,
    });
    await setSessionCookie(token);
    await writeAudit({
      action: "auth.login",
      userId: user.id,
      ip,
      meta: { method: "password" },
    });

    return NextResponse.json({
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        plan: user.plan,
      },
    });
  } catch (err) {
    console.error("login error", err);
    return NextResponse.json({ error: "Login failed" }, { status: 500 });
  }
}
