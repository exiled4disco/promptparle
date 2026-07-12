/**
 * DB-backed login lockout (survives process restarts).
 * Failed password attempts per email; clears on success.
 */

import { prisma } from "./db";

const MAX_FAILS = 8;
const LOCK_MINUTES = 15;

function keyForEmail(email: string) {
  return `email:${email.toLowerCase().trim()}`;
}

export type LockoutStatus = {
  locked: boolean;
  remainingSec: number;
  fails: number;
};

export async function getLoginLockout(email: string): Promise<LockoutStatus> {
  const key = keyForEmail(email);
  const row = await prisma.loginAttempt.findUnique({ where: { key } });
  if (!row) return { locked: false, remainingSec: 0, fails: 0 };
  if (row.lockedUntil && row.lockedUntil > new Date()) {
    return {
      locked: true,
      remainingSec: Math.ceil(
        (row.lockedUntil.getTime() - Date.now()) / 1000
      ),
      fails: row.fails,
    };
  }
  return { locked: false, remainingSec: 0, fails: row.fails };
}

export async function recordLoginFailure(email: string): Promise<LockoutStatus> {
  const key = keyForEmail(email);
  const now = new Date();
  const existing = await prisma.loginAttempt.findUnique({ where: { key } });

  let fails = (existing?.fails || 0) + 1;
  // Reset counter if last lock expired long ago
  if (
    existing?.lockedUntil &&
    existing.lockedUntil < now &&
    existing.fails >= MAX_FAILS
  ) {
    fails = 1;
  }

  const lockedUntil =
    fails >= MAX_FAILS
      ? new Date(now.getTime() + LOCK_MINUTES * 60_000)
      : null;

  await prisma.loginAttempt.upsert({
    where: { key },
    create: {
      key,
      fails,
      lockedUntil,
    },
    update: {
      fails,
      lockedUntil,
    },
  });

  if (lockedUntil) {
    return {
      locked: true,
      remainingSec: LOCK_MINUTES * 60,
      fails,
    };
  }
  return { locked: false, remainingSec: 0, fails };
}

export async function clearLoginFailures(email: string): Promise<void> {
  const key = keyForEmail(email);
  await prisma.loginAttempt
    .deleteMany({ where: { key } })
    .catch(() => {});
}
