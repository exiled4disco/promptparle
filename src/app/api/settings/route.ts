import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import { prisma } from "@/lib/db";
import { listActiveDesktopClients } from "@/lib/desktop-clients";
import { parseAllowedIpsInput } from "@/lib/ip-allowlist";
import { getPlanLimits } from "@/lib/plans";
import { isValidProvider } from "@/lib/providers";
import {
  parsePreferredModelsJson,
  serializePreferredModels,
} from "@/lib/models";

const schema = z.object({
  name: z.string().max(120).optional(),
  retentionPolicy: z.enum(["none", "7d", "30d"]).optional(),
  storePrompts: z.boolean().optional(),
  featProjectPc: z.boolean().optional(),
  featProjectSsh: z.boolean().optional(),
  featProjectGit: z.boolean().optional(),
  /** Free-text IPv4/CIDR list; empty string clears restriction */
  allowedIps: z.string().max(4000).nullable().optional(),
  preferredProvider: z.string().max(40).nullable().optional(),
  preferredModels: z.record(z.string(), z.string().max(120)).optional(),
  defaultDial: z.number().int().min(1).max(5).optional(),
  defaultToolsEnabled: z.boolean().optional(),
});

export async function GET() {
  try {
    const user = await requireUser();
    const limits = getPlanLimits(user.plan);
    const active = await listActiveDesktopClients(user.id);
    return NextResponse.json({
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
        plan: user.plan,
        retentionPolicy: user.retentionPolicy,
        storePrompts: user.storePrompts,
        featProjectPc: user.featProjectPc,
        featProjectSsh: user.featProjectSsh,
        featProjectGit: user.featProjectGit,
        allowedIps: user.allowedIps,
        preferredProvider: user.preferredProvider,
        preferredModels: parsePreferredModelsJson(user.preferredModels),
        defaultDial: user.defaultDial ?? 3,
        defaultToolsEnabled: user.defaultToolsEnabled !== false,
      },
      desktop: {
        max_desktop_clients: limits.maxDesktopClients,
        active_desktop_clients: active.length,
        active_clients: active.map((c) => ({
          client_id: c.clientId,
          hostname: c.hostname,
          platform: c.platform,
          app_version: c.appVersion,
          last_seen_at: c.lastSeenAt,
        })),
      },
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    return NextResponse.json({ error: "Failed to load settings" }, { status: 500 });
  }
}

export async function PATCH(req: NextRequest) {
  try {
    const user = await requireUser();
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid input" }, { status: 400 });
    }

    let allowedIpsValue: string | null | undefined = undefined;
    if (parsed.data.allowedIps !== undefined) {
      const ipParse = parseAllowedIpsInput(parsed.data.allowedIps ?? "");
      if (!ipParse.ok) {
        return NextResponse.json({ error: ipParse.error }, { status: 400 });
      }
      allowedIpsValue = ipParse.normalized;
    }

    let preferredProvider: string | null | undefined = undefined;
    if (parsed.data.preferredProvider !== undefined) {
      if (
        parsed.data.preferredProvider === null ||
        parsed.data.preferredProvider === ""
      ) {
        preferredProvider = null;
      } else if (isValidProvider(parsed.data.preferredProvider.toLowerCase())) {
        preferredProvider = parsed.data.preferredProvider.toLowerCase();
      } else {
        return NextResponse.json(
          { error: "Unknown preferred provider" },
          { status: 400 }
        );
      }
    }

    let preferredModelsJson: string | undefined = undefined;
    if (parsed.data.preferredModels !== undefined) {
      const current = parsePreferredModelsJson(user.preferredModels);
      const merged = { ...current, ...parsed.data.preferredModels };
      preferredModelsJson = serializePreferredModels(merged);
    }

    const updated = await prisma.user.update({
      where: { id: user.id },
      data: {
        ...(parsed.data.name !== undefined
          ? { name: parsed.data.name.trim() || null }
          : {}),
        ...(parsed.data.retentionPolicy !== undefined
          ? { retentionPolicy: parsed.data.retentionPolicy }
          : {}),
        // Product policy: never store prompt/context text (stats + session titles only)
        storePrompts: false,
        ...(parsed.data.featProjectPc !== undefined
          ? { featProjectPc: parsed.data.featProjectPc }
          : {}),
        ...(parsed.data.featProjectSsh !== undefined
          ? { featProjectSsh: parsed.data.featProjectSsh }
          : {}),
        ...(parsed.data.featProjectGit !== undefined
          ? { featProjectGit: parsed.data.featProjectGit }
          : {}),
        ...(allowedIpsValue !== undefined ? { allowedIps: allowedIpsValue } : {}),
        ...(preferredProvider !== undefined
          ? { preferredProvider }
          : {}),
        ...(preferredModelsJson !== undefined
          ? { preferredModels: preferredModelsJson }
          : {}),
        ...(parsed.data.defaultDial !== undefined
          ? {
              defaultDial: Math.min(
                5,
                Math.max(1, parsed.data.defaultDial)
              ),
            }
          : {}),
        ...(parsed.data.defaultToolsEnabled !== undefined
          ? { defaultToolsEnabled: parsed.data.defaultToolsEnabled }
          : {}),
      },
      select: {
        id: true,
        email: true,
        name: true,
        plan: true,
        retentionPolicy: true,
        storePrompts: true,
        featProjectPc: true,
        featProjectSsh: true,
        featProjectGit: true,
        allowedIps: true,
        preferredProvider: true,
        preferredModels: true,
        defaultDial: true,
        defaultToolsEnabled: true,
      },
    });

    return NextResponse.json({
      user: {
        ...updated,
        preferredModels: parsePreferredModelsJson(updated.preferredModels),
      },
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("settings PATCH", err);
    return NextResponse.json({ error: "Failed to update settings" }, { status: 500 });
  }
}
