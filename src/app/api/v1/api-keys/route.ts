import { NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { listApiKeys } from "@/lib/api-keys";

/**
 * Read-only list of desktop API key metadata (prefix only — never full secrets).
 * Used by local UI modal so users need not open the full portal page to glance.
 */
export async function GET(req: Request) {
  try {
    const auth = await requireApiKey(req);
    const keys = await listApiKeys(auth.user.id);
    return NextResponse.json({
      keys: keys.map((k) => ({
        id: k.id,
        name: k.name,
        key_prefix: k.keyPrefix,
        scope: k.scope,
        status: k.status,
        last_used_at: k.lastUsedAt,
        created_at: k.createdAt,
        revoked_at: k.revokedAt,
        is_current: k.id === auth.apiKeyId,
      })),
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/api-keys error", err);
    return NextResponse.json({ error: "Failed to list API keys" }, { status: 500 });
  }
}
