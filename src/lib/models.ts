/**
 * Provider model catalogs — curated defaults + optional live refresh.
 * Models change often; curated list is the stable baseline, live APIs override when possible.
 */

import type { ProviderId } from "./constants";
import { defaultModelFor } from "./providers";

export type ModelInfo = {
  id: string;
  label: string;
  /** curated | live */
  source: "curated" | "live";
  /** optional family tag for UI grouping */
  family?: string;
};

/** In-memory live cache (per process). */
const liveCache = new Map<
  string,
  { at: number; models: ModelInfo[] }
>();
const LIVE_TTL_MS = 60 * 60 * 1000; // 1 hour

/** Curated catalogs — update here when providers ship new defaults. */
const CURATED: Record<ProviderId, ModelInfo[]> = {
  openai: [
    { id: "gpt-4o", label: "GPT-4o", source: "curated", family: "gpt-4o" },
    { id: "gpt-4o-mini", label: "GPT-4o mini", source: "curated", family: "gpt-4o" },
    { id: "gpt-4.1", label: "GPT-4.1", source: "curated", family: "gpt-4.1" },
    { id: "gpt-4.1-mini", label: "GPT-4.1 mini", source: "curated", family: "gpt-4.1" },
    { id: "gpt-4.1-nano", label: "GPT-4.1 nano", source: "curated", family: "gpt-4.1" },
    { id: "o3", label: "o3", source: "curated", family: "o-series" },
    { id: "o3-mini", label: "o3 mini", source: "curated", family: "o-series" },
    { id: "o4-mini", label: "o4 mini", source: "curated", family: "o-series" },
    { id: "gpt-4-turbo", label: "GPT-4 Turbo", source: "curated", family: "gpt-4" },
  ],
  anthropic: [
    {
      id: "claude-sonnet-4-20250514",
      label: "Claude Sonnet 4",
      source: "curated",
      family: "sonnet",
    },
    {
      id: "claude-opus-4-20250514",
      label: "Claude Opus 4",
      source: "curated",
      family: "opus",
    },
    {
      id: "claude-3-7-sonnet-20250219",
      label: "Claude 3.7 Sonnet",
      source: "curated",
      family: "sonnet",
    },
    {
      id: "claude-3-5-sonnet-20241022",
      label: "Claude 3.5 Sonnet",
      source: "curated",
      family: "sonnet",
    },
    {
      id: "claude-3-5-haiku-20241022",
      label: "Claude 3.5 Haiku",
      source: "curated",
      family: "haiku",
    },
    {
      id: "claude-3-opus-20240229",
      label: "Claude 3 Opus",
      source: "curated",
      family: "opus",
    },
  ],
  gemini: [
    {
      id: "gemini-2.0-flash",
      label: "Gemini 2.0 Flash",
      source: "curated",
      family: "flash",
    },
    {
      id: "gemini-2.0-flash-lite",
      label: "Gemini 2.0 Flash Lite",
      source: "curated",
      family: "flash",
    },
    {
      id: "gemini-2.5-pro-preview-05-06",
      label: "Gemini 2.5 Pro (preview)",
      source: "curated",
      family: "pro",
    },
    {
      id: "gemini-1.5-pro",
      label: "Gemini 1.5 Pro",
      source: "curated",
      family: "pro",
    },
    {
      id: "gemini-1.5-flash",
      label: "Gemini 1.5 Flash",
      source: "curated",
      family: "flash",
    },
  ],
  grok: [
    { id: "grok-3", label: "Grok 3", source: "curated", family: "grok-3" },
    {
      id: "grok-3-mini",
      label: "Grok 3 Mini",
      source: "curated",
      family: "grok-3",
    },
    {
      id: "grok-3-fast",
      label: "Grok 3 Fast",
      source: "curated",
      family: "grok-3",
    },
    {
      id: "grok-2-1212",
      label: "Grok 2",
      source: "curated",
      family: "grok-2",
    },
    {
      id: "grok-2-vision-1212",
      label: "Grok 2 Vision",
      source: "curated",
      family: "grok-2",
    },
  ],
};

export function curatedModelsFor(provider: ProviderId): ModelInfo[] {
  return [...(CURATED[provider] || [])];
}

function mergeModels(curated: ModelInfo[], live: ModelInfo[]): ModelInfo[] {
  const byId = new Map<string, ModelInfo>();
  for (const m of curated) byId.set(m.id, m);
  for (const m of live) {
    // live wins for label/source but keep curated order when possible
    byId.set(m.id, { ...byId.get(m.id), ...m, source: "live" });
  }
  // Prefer curated order first, then new live-only ids
  const out: ModelInfo[] = [];
  const seen = new Set<string>();
  for (const m of curated) {
    const hit = byId.get(m.id);
    if (hit) {
      out.push(hit);
      seen.add(m.id);
    }
  }
  for (const m of byId.values()) {
    if (!seen.has(m.id)) out.push(m);
  }
  return out;
}

async function fetchOpenAiModels(apiKey: string): Promise<ModelInfo[]> {
  const res = await fetch("https://api.openai.com/v1/models", {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(12_000),
  });
  if (!res.ok) throw new Error(`openai models ${res.status}`);
  const data = (await res.json()) as { data?: Array<{ id?: string }> };
  const ids = (data.data || [])
    .map((x) => x.id || "")
    .filter((id) => {
      if (!id) return false;
      // chat-useful models only
      if (/^(gpt-|o[1-9]|chatgpt-)/i.test(id)) return true;
      return false;
    })
    .filter((id) => !/instruct|realtime|audio|tts|whisper|embedding|moderation|dall-e|babbage|davinci|curie|ada/i.test(id));
  return ids
    .sort()
    .slice(0, 80)
    .map((id) => ({ id, label: id, source: "live" as const }));
}

async function fetchGeminiModels(apiKey: string): Promise<ModelInfo[]> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(apiKey)}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(12_000) });
  if (!res.ok) throw new Error(`gemini models ${res.status}`);
  const data = (await res.json()) as {
    models?: Array<{ name?: string; displayName?: string; supportedGenerationMethods?: string[] }>;
  };
  const out: ModelInfo[] = [];
  for (const m of data.models || []) {
    const methods = m.supportedGenerationMethods || [];
    if (!methods.includes("generateContent")) continue;
    const raw = m.name || "";
    const id = raw.replace(/^models\//, "");
    if (!id || !/gemini/i.test(id)) continue;
    out.push({
      id,
      label: m.displayName || id,
      source: "live",
    });
  }
  return out.slice(0, 80);
}

async function fetchGrokModels(apiKey: string): Promise<ModelInfo[]> {
  const res = await fetch("https://api.x.ai/v1/models", {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(12_000),
  });
  if (!res.ok) throw new Error(`grok models ${res.status}`);
  const data = (await res.json()) as { data?: Array<{ id?: string }> };
  return (data.data || [])
    .map((x) => x.id || "")
    .filter((id) => id && /grok/i.test(id))
    .sort()
    .slice(0, 40)
    .map((id) => ({ id, label: id, source: "live" as const }));
}

/**
 * List models for a provider. Live refresh uses the user's BYOK key when provided.
 * Falls back to curated catalog on any failure.
 */
export async function listModelsForProvider(opts: {
  provider: ProviderId;
  apiKey?: string | null;
  refresh?: boolean;
}): Promise<{ models: ModelInfo[]; default_model: string; live: boolean }> {
  const provider = opts.provider;
  const curated = curatedModelsFor(provider);
  const def = defaultModelFor(provider);
  const cacheKey = `${provider}:${opts.apiKey ? "k" : "n"}`;

  if (!opts.refresh && liveCache.has(cacheKey)) {
    const hit = liveCache.get(cacheKey)!;
    if (Date.now() - hit.at < LIVE_TTL_MS) {
      return {
        models: mergeModels(curated, hit.models),
        default_model: def,
        live: true,
      };
    }
  }

  let live: ModelInfo[] = [];
  let usedLive = false;
  if (opts.apiKey && opts.refresh !== false) {
    try {
      if (provider === "openai") live = await fetchOpenAiModels(opts.apiKey);
      else if (provider === "gemini") live = await fetchGeminiModels(opts.apiKey);
      else if (provider === "grok") live = await fetchGrokModels(opts.apiKey);
      // Anthropic: no stable public list API — curated only for now
      if (live.length > 0) {
        liveCache.set(cacheKey, { at: Date.now(), models: live });
        usedLive = true;
      }
    } catch {
      /* curated fallback */
    }
  }

  return {
    models: mergeModels(curated, live),
    default_model: def,
    live: usedLive,
  };
}

export function parsePreferredModelsJson(
  raw: string | null | undefined
): Record<string, string> {
  if (!raw) return {};
  try {
    const o = JSON.parse(raw) as unknown;
    if (!o || typeof o !== "object") return {};
    const out: Record<string, string> = {};
    for (const [k, v] of Object.entries(o as Record<string, unknown>)) {
      if (typeof v === "string" && v.trim()) out[k] = v.trim();
    }
    return out;
  } catch {
    return {};
  }
}

export function serializePreferredModels(
  map: Record<string, string>
): string {
  return JSON.stringify(map);
}

/** Resolve model for a request: explicit → user preferred → provider default. */
export function resolveModelForRequest(opts: {
  provider: ProviderId;
  requested?: string | null;
  preferredModels?: Record<string, string> | null;
}): string {
  if (opts.requested && opts.requested.trim()) return opts.requested.trim();
  const pref = opts.preferredModels?.[opts.provider];
  if (pref && pref.trim()) return pref.trim();
  return defaultModelFor(opts.provider);
}
