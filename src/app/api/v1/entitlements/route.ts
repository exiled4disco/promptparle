import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import {
  getUserDesktopFeatures,
  listActiveDesktopClients,
} from "@/lib/desktop-clients";
import { DESKTOP_CLIENT_ACTIVE_MS, getPlanLimits } from "@/lib/plans";

/**
 * Read-only entitlements snapshot (no seat claim). Prefer heartbeat for seat.
 */
export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const limits = getPlanLimits(auth.user.plan);
    const features = await getUserDesktopFeatures(auth.user.id);
    const active = await listActiveDesktopClients(auth.user.id);

    return NextResponse.json({
      plan: limits.id,
      plan_label: limits.label,
      max_desktop_clients: limits.maxDesktopClients,
      active_desktop_clients: active.length,
      active_clients: active.map((c) => ({
        client_id: c.clientId,
        hostname: c.hostname,
        platform: c.platform,
        app_version: c.appVersion,
        last_seen_at: c.lastSeenAt,
      })),
      project_pc: features.projectPc,
      project_ssh: features.projectSsh,
      project_git: features.projectGit,
      seat_window_seconds: Math.round(DESKTOP_CLIENT_ACTIVE_MS / 1000),
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/entitlements", err);
    return NextResponse.json(
      { error: "Failed to load entitlements" },
      { status: 500 }
    );
  }
}
