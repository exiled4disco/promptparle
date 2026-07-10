import { NextRequest, NextResponse } from "next/server";
import { consumeVerificationToken } from "@/lib/email-verification";
import { createSession, setSessionCookie } from "@/lib/auth";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json().catch(() => ({}));
    const token =
      typeof body.token === "string"
        ? body.token
        : req.nextUrl.searchParams.get("token") || "";

    const result = await consumeVerificationToken(token);
    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: 400 });
    }

    const sessionToken = await createSession(result.userId, {
      userAgent: req.headers.get("user-agent") || undefined,
      ipAddress: req.headers.get("x-forwarded-for") || undefined,
    });
    await setSessionCookie(sessionToken);

    return NextResponse.json({ ok: true });
  } catch (err) {
    console.error("verify-email error", err);
    return NextResponse.json({ error: "Verification failed" }, { status: 500 });
  }
}

/** GET support for simple link clicks that hit the API directly. */
export async function GET(req: NextRequest) {
  const token = req.nextUrl.searchParams.get("token") || "";
  const result = await consumeVerificationToken(token);

  const base = process.env.NEXT_PUBLIC_APP_URL || "https://promptparle.com";
  if (!result.ok) {
    return NextResponse.redirect(
      `${base}/verify-email?error=${encodeURIComponent(result.error)}`
    );
  }

  const sessionToken = await createSession(result.userId, {
    userAgent: req.headers.get("user-agent") || undefined,
    ipAddress: req.headers.get("x-forwarded-for") || undefined,
  });
  await setSessionCookie(sessionToken);

  return NextResponse.redirect(`${base}/app`);
}
