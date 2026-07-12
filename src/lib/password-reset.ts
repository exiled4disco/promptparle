/**
 * Forgot-password: create + consume short-lived reset tokens.
 * Always return generic responses from API routes (no email enumeration).
 */

import { prisma } from "./db";
import { randomToken, sha256 } from "./crypto";
import { hashPassword } from "./auth";
import { sendPasswordResetEmail } from "./mail";
import { clearLoginFailures } from "./login-lockout";

const TOKEN_TTL_HOURS = 1;

export async function createAndSendPasswordReset(emailRaw: string): Promise<void> {
  const email = emailRaw.toLowerCase().trim();
  const user = await prisma.user.findUnique({
    where: { email },
    select: { id: true, email: true, name: true, emailVerifiedAt: true },
  });

  // Silent no-op for unknown / unverified (avoid enumeration + unusable resets)
  if (!user || !user.emailVerifiedAt) {
    return;
  }

  await prisma.passwordResetToken.updateMany({
    where: { userId: user.id, usedAt: null },
    data: { usedAt: new Date() },
  });

  const rawToken = randomToken(32);
  const expiresAt = new Date();
  expiresAt.setHours(expiresAt.getHours() + TOKEN_TTL_HOURS);

  await prisma.passwordResetToken.create({
    data: {
      userId: user.id,
      tokenHash: sha256(rawToken),
      expiresAt,
    },
  });

  await sendPasswordResetEmail(user.email, rawToken, user.name);
}

export async function consumePasswordReset(opts: {
  rawToken: string;
  newPassword: string;
}): Promise<{ ok: true; userId: string } | { ok: false; error: string }> {
  const { rawToken, newPassword } = opts;
  if (!rawToken || rawToken.length < 16) {
    return { ok: false, error: "Invalid or expired reset link" };
  }
  if (newPassword.length < 8 || newPassword.length > 128) {
    return { ok: false, error: "Password must be 8-128 characters" };
  }

  const tokenHash = sha256(rawToken);
  const record = await prisma.passwordResetToken.findUnique({
    where: { tokenHash },
    include: { user: { select: { id: true, email: true } } },
  });

  if (!record || record.usedAt || record.expiresAt < new Date()) {
    return { ok: false, error: "Invalid or expired reset link" };
  }

  const passwordHash = await hashPassword(newPassword);

  await prisma.$transaction([
    prisma.passwordResetToken.update({
      where: { id: record.id },
      data: { usedAt: new Date() },
    }),
    prisma.user.update({
      where: { id: record.userId },
      data: { passwordHash },
    }),
    // Kill other open sessions after password reset
    prisma.session.deleteMany({ where: { userId: record.userId } }),
    prisma.passwordResetToken.updateMany({
      where: {
        userId: record.userId,
        usedAt: null,
        id: { not: record.id },
      },
      data: { usedAt: new Date() },
    }),
  ]);

  await clearLoginFailures(record.user.email);
  return { ok: true, userId: record.userId };
}

/** Authenticated password change / set (OAuth users may set first password). */
export async function changePasswordForUser(opts: {
  userId: string;
  currentPassword?: string | null;
  newPassword: string;
  keepSessionTokenHash?: string | null;
}): Promise<{ ok: true } | { ok: false; error: string; status: number }> {
  const { userId, currentPassword, newPassword, keepSessionTokenHash } = opts;
  if (newPassword.length < 8 || newPassword.length > 128) {
    return {
      ok: false,
      error: "Password must be 8-128 characters",
      status: 400,
    };
  }

  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { id: true, email: true, passwordHash: true },
  });
  if (!user) {
    return { ok: false, error: "User not found", status: 404 };
  }

  const { verifyPassword } = await import("./auth");

  if (user.passwordHash) {
    if (!currentPassword) {
      return {
        ok: false,
        error: "Current password is required",
        status: 400,
      };
    }
    const ok = await verifyPassword(currentPassword, user.passwordHash);
    if (!ok) {
      return { ok: false, error: "Current password is incorrect", status: 401 };
    }
  }
  // OAuth-only (no passwordHash): allow setting without current password

  const passwordHash = await hashPassword(newPassword);

  await prisma.$transaction(async (tx) => {
    await tx.user.update({
      where: { id: userId },
      data: { passwordHash },
    });
    // Drop other sessions; keep the current one if we know its hash
    if (keepSessionTokenHash) {
      await tx.session.deleteMany({
        where: {
          userId,
          tokenHash: { not: keepSessionTokenHash },
        },
      });
    } else {
      await tx.session.deleteMany({ where: { userId } });
    }
  });

  await clearLoginFailures(user.email);
  return { ok: true };
}
