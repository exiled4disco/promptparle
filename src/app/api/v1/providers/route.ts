import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { PROVIDERS } from "@/lib/constants";
import { listProviderCredentials } from "@/lib/providers";

/** List available providers + which keys the caller has configured. */
export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const credentials = await listProviderCredentials(auth.user.id);
    const configured = new Set(
      credentials.filter((c) => c.status === "active").map((c) => c.provider)
    );

    return NextResponse.json({
      providers: PROVIDERS.filter((p) => p.enabled).map((p) => ({
        id: p.id,
        name: p.name,
        routing: p.routing,
        default_model: p.defaultModel,
        configured: configured.has(p.id),
      })),
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/providers error", err);
    return NextResponse.json({ error: "Failed to list providers" }, { status: 500 });
  }
}
