import { prisma } from "./db";
import { decryptSecret, encryptSecret, lastFour } from "./crypto";
import { PROVIDERS, getProviderMeta, type ProviderId } from "./constants";

export function isValidProvider(id: string): id is ProviderId {
  return PROVIDERS.some((p) => p.id === id);
}

/** Key storage allowed in portal */
export function isProviderEnabled(id: string): boolean {
  return PROVIDERS.some((p) => p.id === id && p.enabled);
}

/** Live /v1/prompt routing supported */
export function isProviderRoutable(id: string): boolean {
  return PROVIDERS.some((p) => p.id === id && p.enabled && p.routing);
}

export async function listProviderCredentials(userId: string) {
  const rows = await prisma.providerCredential.findMany({
    where: { userId },
    orderBy: { createdAt: "desc" },
    select: {
      id: true,
      provider: true,
      label: true,
      keyLastFour: true,
      status: true,
      createdAt: true,
      lastUsedAt: true,
    },
  });
  return rows;
}

export async function upsertProviderCredential(
  userId: string,
  provider: ProviderId,
  apiKey: string,
  label?: string
) {
  const encryptedKey = encryptSecret(apiKey.trim());
  const keyLastFour = lastFour(apiKey);

  return prisma.providerCredential.upsert({
    where: {
      userId_provider: { userId, provider },
    },
    create: {
      userId,
      provider,
      label: label?.trim() || null,
      encryptedKey,
      keyLastFour,
      status: "active",
    },
    update: {
      encryptedKey,
      keyLastFour,
      label: label?.trim() || null,
      status: "active",
    },
    select: {
      id: true,
      provider: true,
      label: true,
      keyLastFour: true,
      status: true,
      createdAt: true,
      lastUsedAt: true,
    },
  });
}

export async function revokeProviderCredential(userId: string, id: string) {
  return prisma.providerCredential.updateMany({
    where: { id, userId },
    data: { status: "revoked" },
  });
}

export async function deleteProviderCredential(userId: string, id: string) {
  return prisma.providerCredential.deleteMany({
    where: { id, userId },
  });
}

/**
 * Load decrypted provider API key for routing.
 * Never log the return value.
 */
export async function getActiveProviderKey(
  userId: string,
  provider: ProviderId
): Promise<{ apiKey: string; credentialId: string } | null> {
  const row = await prisma.providerCredential.findUnique({
    where: {
      userId_provider: { userId, provider },
    },
  });
  if (!row || row.status !== "active") return null;
  return {
    apiKey: decryptSecret(row.encryptedKey),
    credentialId: row.id,
  };
}

export function defaultModelFor(provider: ProviderId): string {
  return getProviderMeta(provider)?.defaultModel || "unknown";
}

export async function touchProviderCredential(credentialId: string) {
  await prisma.providerCredential.update({
    where: { id: credentialId },
    data: { lastUsedAt: new Date() },
  });
}
