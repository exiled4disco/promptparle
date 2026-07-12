import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import {
  acceptInvitation,
  acceptInvitationByCode,
} from "@/lib/invitations";
import { setSessionCookie } from "@/lib/auth";
import { checkRateLimit, RL, rateLimitResponse } from "@/lib/rate-limit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";
import { writeAudit } from "@/lib/audit";

const schema = z
  .object({
    token: z.string().min(16).max(200).optional(),
    code: z.string().min(6).max(32).optional(),
    name: z.string().max(120).optional().nullable(),
    password: z.string().min(8).max(128),
  })
  .refine((d) => Boolean(d.token || d.code), {
    message: "Invitation token or code required",
  });

export async function POST(req: NextRequest) {
  try {
    const ip = getClientIpFromHeaders(req.headers) || "unknown";
    const rl = checkRateLimit(
      `invite-accept:${ip}`,
      RL.registerIp.max,
      RL.registerIp.windowMs
    );
    if (!rl.ok) {
      const r = rateLimitResponse(rl.retryAfterSec);
      return NextResponse.json(r.body, { status: r.status, headers: r.headers });
    }

    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        {
          error:
            "Invitation code (or email link) and password (8+ characters) required.",
        },
        { status: 400 }
      );
    }

    const result = parsed.data.token
      ? await acceptInvitation({
          rawToken: parsed.data.token,
          name: parsed.data.name,
          password: parsed.data.password,
        })
      : await acceptInvitationByCode({
          code: parsed.data.code!,
          name: parsed.data.name,
          password: parsed.data.password,
        });

    if (!result.ok) {
      return NextResponse.json(
        { error: result.error },
        { status: result.status }
      );
    }

    await setSessionCookie(result.sessionToken);
    await writeAudit({
      action: "auth.register",
      userId: result.userId,
      ip,
      meta: {
        method: parsed.data.token ? "invitation_link" : "invitation_code",
        code: result.code,
      },
    });

    return NextResponse.json({
      ok: true,
      code: result.code,
      message:
        "Account created. Check your email for desktop install steps. Use the same invitation code in the installer.",
    });
  } catch (err) {
    console.error("invite accept", err);
    return NextResponse.json(
      { error: "Could not complete invitation" },
      { status: 500 }
    );
  }
}
