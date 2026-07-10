import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { createAndSendVerification } from "@/lib/email-verification";
import { isMailConfigured } from "@/lib/mail";

const schema = z.object({
  email: z.string().email(),
});

// Simple in-memory rate limit (per process): 1 resend / 60s / email
const lastSent = new Map<string, number>();
const COOLDOWN_MS = 60_000;

export async function POST(req: NextRequest) {
  try {
    if (!isMailConfigured()) {
      return NextResponse.json(
        { error: "Email delivery is not configured" },
        { status: 503 }
      );
    }

    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Valid email required" }, { status: 400 });
    }

    const email = parsed.data.email.toLowerCase().trim();
    const now = Date.now();
    const prev = lastSent.get(email) || 0;
    if (now - prev < COOLDOWN_MS) {
      return NextResponse.json(
        { error: "Please wait a minute before requesting another email." },
        { status: 429 }
      );
    }

    const user = await prisma.user.findUnique({ where: { email } });

    // Always return success-shaped response to avoid email enumeration
    const generic = {
      ok: true,
      message:
        "If an unverified account exists for that email, a new link has been sent.",
    };

    if (!user || user.emailVerifiedAt) {
      return NextResponse.json(generic);
    }

    try {
      await createAndSendVerification({
        id: user.id,
        email: user.email,
        name: user.name,
      });
      lastSent.set(email, now);
    } catch (err) {
      console.error("resend verification failed", err);
      return NextResponse.json(
        { error: "Could not send verification email. Try again later." },
        { status: 502 }
      );
    }

    return NextResponse.json(generic);
  } catch (err) {
    console.error("resend-verification error", err);
    return NextResponse.json({ error: "Request failed" }, { status: 500 });
  }
}
