import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { isValidProvider, getActiveProviderKey } from "@/lib/providers";
import type { ProviderId } from "@/lib/constants";
import {
  listModelsForProvider,
  parsePreferredModelsJson,
} from "@/lib/models";

/**
 * GET /api/v1/models?provider=openai&refresh=1
 * Dynamic model list for desktop chat selector.
 * Live-refresh when the account has a key for that provider.
 */
export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const provider = (req.nextUrl.searchParams.get("provider") || "").toLowerCase();
    const refresh =
      req.nextUrl.searchParams.get("refresh") === "1" ||
      req.nextUrl.searchParams.get("refresh") === "true";

    if (!provider || !isValidProvider(provider)) {
      return NextResponse.json(
        { error: "Query provider=openai|anthropic|gemini|grok required" },
        { status: 400 }
      );
    }

    const providerId = provider as ProviderId;
    let apiKey: string | null = null;
    try {
      const cred = await getActiveProviderKey(auth.user.id, providerId);
      apiKey = cred?.apiKey || null;
    } catch {
      apiKey = null;
    }

    const listed = await listModelsForProvider({
      provider: providerId,
      apiKey,
      refresh: refresh || Boolean(apiKey),
    });

    const preferred = parsePreferredModelsJson(auth.user.preferredModels);
    const preferredModel =
      preferred[providerId] || listed.default_model || null;

    return NextResponse.json({
      provider: providerId,
      default_model: listed.default_model,
      preferred_model: preferredModel,
      live: listed.live,
      models: listed.models.map((m) => ({
        id: m.id,
        label: m.label,
        source: m.source,
        family: m.family || null,
      })),
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/models", err);
    return NextResponse.json({ error: "Failed to list models" }, { status: 500 });
  }
}
