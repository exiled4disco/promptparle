import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { prisma } from "@/lib/db";
import { hashPassword } from "@/lib/auth";
import { createAndSendVerification } from "@/lib/email-verification";
import { isMailConfigured } from "@/lib/mail";

const schema = z.object({
  email: z.string().email().max(255),
  password: z.string().min(8).max(128),
  name: z.string().max(120).optional(),
});

export async function POST(req: NextRequest) {
  try {
    if (!isMailConfigured()) {
      return NextResponse.json(
        {
          error:
            "Email delivery is not configured on this server. Contact support.",
        },
        { status: 503 }
      );
    }

    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Invalid input", details: parsed.error.flatten() },
        { status: 400 }
      );
    }

    const email = parsed.data.email.toLowerCase().trim();
    const existing = await prisma.user.findUnique({ where: { email } });
    if (existing) {
      // Do not reveal whether the address is verified — generic message
      if (!existing.emailVerifiedAt) {
        // Allow re-send path: same password not required for security; ask them to use resend
        return NextResponse.json(
          {
            error:
              "An account with this email already exists. Sign in, or resend the verification email.",
            code: "exists_unverified",
          },
          { status: 409 }
        );
      }
      return NextResponse.json(
        { error: "An account with this email already exists" },
        { status: 409 }
      );
    }

    const passwordHash = await hashPassword(parsed.data.password);
    const user = await prisma.user.create({
      data: {
        email,
        name: parsed.data.name?.trim() || null,
        passwordHash,
        plan: "free",
        emailVerifiedAt: null,
      },
    });

    try {
      await createAndSendVerification({
        id: user.id,
        email: user.email,
        name: user.name,
      });
    } catch (mailErr) {
      console.error("verification email failed", mailErr);
      // Roll back account so user can retry cleanly
      await prisma.user.delete({ where: { id: user.id } }).catch(() => {});
      return NextResponse.json(
        {
          error:
            "We could not send the verification email. Please try again in a few minutes.",
        },
        { status: 502 }
      );
    }

    // No session until email is verified
    return NextResponse.json({
      ok: true,
      requiresVerification: true,
      email: user.email,
      message:
        "Check your email for a verification link to activate your account.",
    });
  } catch (err) {
    console.error("register error", err);
    return NextResponse.json({ error: "Registration failed" }, { status: 500 });
  }
}
