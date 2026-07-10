import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import { prisma } from "@/lib/db";
import { listActiveDesktopClients } from "@/lib/desktop-clients";
import { getPlanLimits } from "@/lib/plans";

const schema = z.object({
  name: z.string().max(120).optional(),
  retentionPolicy: z.enum(["none", "7d", "30d"]).optional(),
  storePrompts: z.boolean().optional(),
  featProjectPc: z.boolean().optional(),
  featProjectSsh: z.boolean().optional(),
  featProjectGit: z.boolean().optional(),
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

    const updated = await prisma.user.update({
      where: { id: user.id },
      data: {
        ...(parsed.data.name !== undefined
          ? { name: parsed.data.name.trim() || null }
          : {}),
        ...(parsed.data.retentionPolicy !== undefined
          ? { retentionPolicy: parsed.data.retentionPolicy }
          : {}),
        ...(parsed.data.storePrompts !== undefined
          ? { storePrompts: parsed.data.storePrompts }
          : {}),
        ...(parsed.data.featProjectPc !== undefined
          ? { featProjectPc: parsed.data.featProjectPc }
          : {}),
        ...(parsed.data.featProjectSsh !== undefined
          ? { featProjectSsh: parsed.data.featProjectSsh }
          : {}),
        ...(parsed.data.featProjectGit !== undefined
          ? { featProjectGit: parsed.data.featProjectGit }
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
      },
    });

    return NextResponse.json({ user: updated });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("settings PATCH", err);
    return NextResponse.json({ error: "Failed to update settings" }, { status: 500 });
  }
}
