import { NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { prisma } from "@/lib/db";

/**
 * Mark the setup walkthrough as done (finished or skipped) so the user isn't
 * redirected into it again. Idempotent.
 */
export async function POST() {
  try {
    const user = await requireUser();
    await prisma.user.update({
      where: { id: user.id },
      data: { onboardedAt: new Date() },
    });
    return NextResponse.json({ ok: true });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("onboarding POST", err);
    return NextResponse.json({ error: "Failed to update" }, { status: 500 });
  }
}
