import { prisma } from "./db";
import { randomToken, sha256 } from "./crypto";
import { sendVerificationEmail } from "./mail";

const TOKEN_TTL_HOURS = 24;

export async function createAndSendVerification(
  user: { id: string; email: string; name: string | null }
): Promise<void> {
  // Invalidate prior unused tokens
  await prisma.emailVerificationToken.updateMany({
    where: { userId: user.id, usedAt: null },
    data: { usedAt: new Date() },
  });

  const rawToken = randomToken(32);
  const expiresAt = new Date();
  expiresAt.setHours(expiresAt.getHours() + TOKEN_TTL_HOURS);

  await prisma.emailVerificationToken.create({
    data: {
      userId: user.id,
      tokenHash: sha256(rawToken),
      expiresAt,
    },
  });

  await sendVerificationEmail(user.email, rawToken, user.name);
}

export async function consumeVerificationToken(
  rawToken: string
): Promise<{ ok: true; userId: string } | { ok: false; error: string }> {
  if (!rawToken || rawToken.length < 16) {
    return { ok: false, error: "Invalid verification link" };
  }

  const tokenHash = sha256(rawToken);
  const record = await prisma.emailVerificationToken.findUnique({
    where: { tokenHash },
  });

  if (!record) {
    return { ok: false, error: "Invalid or expired verification link" };
  }
  if (record.usedAt) {
    return { ok: false, error: "This verification link was already used" };
  }
  if (record.expiresAt < new Date()) {
    return { ok: false, error: "This verification link has expired" };
  }

  await prisma.$transaction([
    prisma.emailVerificationToken.update({
      where: { id: record.id },
      data: { usedAt: new Date() },
    }),
    prisma.user.update({
      where: { id: record.userId },
      data: { emailVerifiedAt: new Date() },
    }),
    // Invalidate other pending tokens for this user
    prisma.emailVerificationToken.updateMany({
      where: {
        userId: record.userId,
        usedAt: null,
        id: { not: record.id },
      },
      data: { usedAt: new Date() },
    }),
  ]);

  return { ok: true, userId: record.userId };
}
