import { prisma } from "./db";
import {
  DESKTOP_CLIENT_ACTIVE_MS,
  getPlanLimits,
} from "./plans";
import { parsePreferredModelsJson } from "./models";

export type DesktopFeatureFlags = {
  projectPc: boolean;
  projectSsh: boolean;
  projectGit: boolean;
};

export type DesktopChatPrefs = {
  preferred_provider: string | null;
  preferred_models: Record<string, string>;
  default_dial: number;
  default_tools_enabled: boolean;
};

export type DesktopEntitlements = {
  plan: string;
  plan_label: string;
  max_desktop_clients: number;
  active_desktop_clients: number;
  allowed: boolean;
  message: string | null;
  project_pc: boolean;
  project_ssh: boolean;
  project_git: boolean;
  preferred_provider: string | null;
  preferred_models: Record<string, string>;
  default_dial: number;
  default_tools_enabled: boolean;
  client_id: string;
  seat_window_seconds: number;
};

export async function getUserDesktopFeatures(
  userId: string
): Promise<DesktopFeatureFlags> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: {
      featProjectPc: true,
      featProjectSsh: true,
      featProjectGit: true,
    },
  });
  return {
    projectPc: user?.featProjectPc !== false,
    projectSsh: user?.featProjectSsh !== false,
    projectGit: user?.featProjectGit !== false,
  };
}

export async function getUserDesktopChatPrefs(
  userId: string
): Promise<DesktopChatPrefs> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: {
      preferredProvider: true,
      preferredModels: true,
      defaultDial: true,
      defaultToolsEnabled: true,
    },
  });
  return {
    preferred_provider: user?.preferredProvider || null,
    preferred_models: parsePreferredModelsJson(user?.preferredModels),
    default_dial: user?.defaultDial ?? 3,
    default_tools_enabled: user?.defaultToolsEnabled !== false,
  };
}

/**
 * Register / refresh a desktop client seat.
 * Free plan: max 1 concurrent client (other active clients block new machines).
 */
export async function heartbeatDesktopClient(opts: {
  userId: string;
  plan: string;
  clientId: string;
  hostname?: string | null;
  platform?: string | null;
  appVersion?: string | null;
}): Promise<DesktopEntitlements> {
  const limits = getPlanLimits(opts.plan);
  const max = limits.maxDesktopClients;
  const clientId = opts.clientId.trim().slice(0, 128);
  if (!clientId || clientId.length < 8) {
    throw new DesktopClientError("Invalid client_id", 400);
  }

  const now = new Date();
  const activeSince = new Date(now.getTime() - DESKTOP_CLIENT_ACTIVE_MS);

  const features = await getUserDesktopFeatures(opts.userId);
  const chatPrefs = await getUserDesktopChatPrefs(opts.userId);

  // Other machines currently holding a seat
  const otherActive = await prisma.desktopClient.count({
    where: {
      userId: opts.userId,
      clientId: { not: clientId },
      lastSeenAt: { gte: activeSince },
    },
  });

  if (otherActive >= max) {
    return {
      plan: limits.id,
      plan_label: limits.label,
      max_desktop_clients: max,
      active_desktop_clients: otherActive,
      allowed: false,
      message: `Desktop client limit reached (${limits.label}: ${max} active). Close PromptParle on another PC, wait ~2 minutes, or upgrade.`,
      project_pc: features.projectPc,
      project_ssh: features.projectSsh,
      project_git: features.projectGit,
      preferred_provider: chatPrefs.preferred_provider,
      preferred_models: chatPrefs.preferred_models,
      default_dial: chatPrefs.default_dial,
      default_tools_enabled: chatPrefs.default_tools_enabled,
      client_id: clientId,
      seat_window_seconds: Math.round(DESKTOP_CLIENT_ACTIVE_MS / 1000),
    };
  }

  await prisma.desktopClient.upsert({
    where: {
      userId_clientId: {
        userId: opts.userId,
        clientId,
      },
    },
    create: {
      userId: opts.userId,
      clientId,
      hostname: opts.hostname?.slice(0, 120) || null,
      platform: opts.platform?.slice(0, 40) || null,
      appVersion: opts.appVersion?.slice(0, 40) || null,
      lastSeenAt: now,
    },
    update: {
      hostname: opts.hostname?.slice(0, 120) || null,
      platform: opts.platform?.slice(0, 40) || null,
      appVersion: opts.appVersion?.slice(0, 40) || null,
      lastSeenAt: now,
    },
  });

  // Best-effort prune very old rows (keep table small)
  const pruneBefore = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000);
  await prisma.desktopClient
    .deleteMany({
      where: {
        userId: opts.userId,
        lastSeenAt: { lt: pruneBefore },
        clientId: { not: clientId },
      },
    })
    .catch(() => {});

  const activeTotal = otherActive + 1;

  return {
    plan: limits.id,
    plan_label: limits.label,
    max_desktop_clients: max,
    active_desktop_clients: activeTotal,
    allowed: true,
    message: null,
    project_pc: features.projectPc,
    project_ssh: features.projectSsh,
    project_git: features.projectGit,
    preferred_provider: chatPrefs.preferred_provider,
    preferred_models: chatPrefs.preferred_models,
    default_dial: chatPrefs.default_dial,
    default_tools_enabled: chatPrefs.default_tools_enabled,
    client_id: clientId,
    seat_window_seconds: Math.round(DESKTOP_CLIENT_ACTIVE_MS / 1000),
  };
}

export async function listActiveDesktopClients(userId: string) {
  const activeSince = new Date(Date.now() - DESKTOP_CLIENT_ACTIVE_MS);
  return prisma.desktopClient.findMany({
    where: {
      userId,
      lastSeenAt: { gte: activeSince },
    },
    orderBy: { lastSeenAt: "desc" },
    select: {
      clientId: true,
      hostname: true,
      platform: true,
      appVersion: true,
      lastSeenAt: true,
    },
  });
}

export class DesktopClientError extends Error {
  status: number;
  constructor(message: string, status = 400) {
    super(message);
    this.name = "DesktopClientError";
    this.status = status;
  }
}
