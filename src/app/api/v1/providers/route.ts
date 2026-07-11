import { NextRequest, NextResponse } from "next/server";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { PROVIDERS } from "@/lib/constants";
import {
  listProviderCredentials,
  getActiveProviderKey,
  isValidProvider,
} from "@/lib/providers";
import type { ProviderId } from "@/lib/constants";
import {
  listModelsForProvider,
  parsePreferredModelsJson,
} from "@/lib/models";

/** List available providers + keys + model catalogs (for desktop chat selector). */
export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const credentials = await listProviderCredentials(auth.user.id);
    const configured = new Set(
      credentials.filter((c) => c.status === "active").map((c) => c.provider)
    );
    const preferredModels = parsePreferredModelsJson(auth.user.preferredModels);
    const includeModels =
      req.nextUrl.searchParams.get("models") !== "0" &&
      req.nextUrl.searchParams.get("models") !== "false";
    const refresh =
      req.nextUrl.searchParams.get("refresh") === "1" ||
      req.nextUrl.searchParams.get("refresh") === "true";

    const providers = [];
    for (const p of PROVIDERS.filter((x) => x.enabled)) {
      const entry: Record<string, unknown> = {
        id: p.id,
        name: p.name,
        routing: p.routing,
        default_model: p.defaultModel,
        preferred_model: preferredModels[p.id] || p.defaultModel,
        configured: configured.has(p.id),
      };

      if (includeModels) {
        let apiKey: string | null = null;
        if (configured.has(p.id) && isValidProvider(p.id)) {
          try {
            const cred = await getActiveProviderKey(
              auth.user.id,
              p.id as ProviderId
            );
            apiKey = cred?.apiKey || null;
          } catch {
            apiKey = null;
          }
        }
        const listed = await listModelsForProvider({
          provider: p.id as ProviderId,
          apiKey,
          refresh: refresh && Boolean(apiKey),
        });
        entry.models = listed.models.map((m) => ({
          id: m.id,
          label: m.label,
          source: m.source,
          family: m.family || null,
        }));
        entry.models_live = listed.live;
      }

      providers.push(entry);
    }

    return NextResponse.json({
      providers,
      preferred_provider: auth.user.preferredProvider || null,
      preferred_models: preferredModels,
      default_dial: auth.user.defaultDial ?? 3,
      default_tools_enabled: auth.user.defaultToolsEnabled !== false,
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/providers error", err);
    return NextResponse.json({ error: "Failed to list providers" }, { status: 500 });
  }
}
