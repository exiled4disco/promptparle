import { randomBytes, createHash } from "crypto";
import { prisma } from "./db";

/**
 * Generate a PromptParle desktop API key.
 * Format: pp_live_<32 hex chars>
 * Only the hash is stored; full key returned once.
 */
export function generateDesktopApiKey(): {
  fullKey: string;
  keyHash: string;
  keyPrefix: string;
} {
  const secret = randomBytes(24).toString("hex");
  const fullKey = `pp_live_${secret}`;
  const keyHash = hashApiKey(fullKey);
  const keyPrefix = `pp_live_${secret.slice(0, 4)}`;
  return { fullKey, keyHash, keyPrefix };
}

export function hashApiKey(fullKey: string): string {
  return createHash("sha256").update(fullKey).digest("hex");
}

export async function createApiKey(userId: string, name: string) {
  const { fullKey, keyHash, keyPrefix } = generateDesktopApiKey();
  const record = await prisma.apiKey.create({
    data: {
      userId,
      name: name.trim() || "Desktop",
      keyHash,
      keyPrefix,
      scope: "desktop",
      status: "active",
    },
  });
  return { record, fullKey };
}

export async function listApiKeys(userId: string) {
  return prisma.apiKey.findMany({
    where: { userId },
    orderBy: { createdAt: "desc" },
    select: {
      id: true,
      name: true,
      keyPrefix: true,
      scope: true,
      status: true,
      lastUsedAt: true,
      createdAt: true,
      revokedAt: true,
    },
  });
}

export async function revokeApiKey(userId: string, keyId: string) {
  return prisma.apiKey.updateMany({
    where: { id: keyId, userId, status: "active" },
    data: { status: "revoked", revokedAt: new Date() },
  });
}

/** Resolve a desktop API key to a user. */
export async function authenticateApiKey(fullKey: string) {
  const keyHash = hashApiKey(fullKey.trim());
  const key = await prisma.apiKey.findUnique({
    where: { keyHash },
    include: {
      user: {
        select: {
          id: true,
          email: true,
          plan: true,
          retentionPolicy: true,
          storePrompts: true,
          emailVerifiedAt: true,
        },
      },
    },
  });
  if (!key || key.status !== "active") return null;
  await prisma.apiKey.update({
    where: { id: key.id },
    data: { lastUsedAt: new Date() },
  });
  return { key, user: key.user };
}
