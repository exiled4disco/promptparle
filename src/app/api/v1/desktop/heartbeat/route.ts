import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import {
  DesktopClientError,
  heartbeatDesktopClient,
} from "@/lib/desktop-clients";

const schema = z.object({
  client_id: z.string().min(8).max(128),
  hostname: z.string().max(120).optional().nullable(),
  platform: z.string().max(40).optional().nullable(),
  app_version: z.string().max(40).optional().nullable(),
});

/**
 * Desktop UI heartbeat — claims a concurrent seat and returns feature flags.
 * Free plan: max 1 active desktop client.
 */
export async function POST(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const body = await req.json().catch(() => ({}));
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Invalid body. Need client_id (stable desktop id)." },
        { status: 400 }
      );
    }

    const entitlements = await heartbeatDesktopClient({
      userId: auth.user.id,
      plan: auth.user.plan,
      clientId: parsed.data.client_id,
      hostname: parsed.data.hostname,
      platform: parsed.data.platform,
      appVersion: parsed.data.app_version,
    });

    // Always 200 with allowed flag so desktop clients parse the full payload
    // (403 would drop structured fields through some HTTP clients).
    return NextResponse.json(entitlements);
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    if (err instanceof DesktopClientError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/desktop/heartbeat", err);
    return NextResponse.json(
      { error: "Desktop heartbeat failed" },
      { status: 500 }
    );
  }
}
