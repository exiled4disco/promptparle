/**
 * Provider model catalogs: curated defaults + optional live refresh.
 * Models change often; curated list is the stable baseline, live APIs override when possible.
 * Each provider's list is isolated: never mix OpenAI ids into Grok, etc.
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

/**
 * True when a model id is plausible for the given provider.
 * Used to keep chat selectors from showing foreign models after provider switch.
 */
export function modelBelongsToProvider(
  provider: string,
  modelId: string | null | undefined
): boolean {
  if (!modelId || !provider) return false;
  const id = modelId.trim().toLowerCase();
  if (!id) return false;
  switch (provider.toLowerCase()) {
    case "openai":
      return /^(gpt-|o[1-9]|chatgpt-|ft:gpt-)/i.test(id);
    case "anthropic":
      return /claude/i.test(id);
    case "gemini":
      return /gemini/i.test(id);
    case "grok":
      return /grok/i.test(id);
    default:
      return false;
  }
}

/** Curated catalogs: update when providers ship new flagship models. */
const CURATED: Record<ProviderId, ModelInfo[]> = {
  // OpenAI: 2026-07 live probe (newest flagships first). Live list merges the rest.
  openai: [
    { id: "gpt-5.5", label: "GPT-5.5", source: "curated", family: "gpt-5" },
    { id: "gpt-5.5-pro", label: "GPT-5.5 Pro", source: "curated", family: "gpt-5" },
    { id: "gpt-5.4", label: "GPT-5.4", source: "curated", family: "gpt-5" },
    { id: "gpt-5.4-mini", label: "GPT-5.4 mini", source: "curated", family: "gpt-5" },
    { id: "gpt-5.4-nano", label: "GPT-5.4 nano", source: "curated", family: "gpt-5" },
    { id: "gpt-5.4-pro", label: "GPT-5.4 Pro", source: "curated", family: "gpt-5" },
    { id: "gpt-5.3-chat-latest", label: "GPT-5.3 Chat", source: "curated", family: "gpt-5" },
    { id: "gpt-5.3-codex", label: "GPT-5.3 Codex", source: "curated", family: "gpt-5" },
    { id: "gpt-5.2", label: "GPT-5.2", source: "curated", family: "gpt-5" },
    { id: "gpt-5.2-pro", label: "GPT-5.2 Pro", source: "curated", family: "gpt-5" },
    { id: "gpt-5.2-codex", label: "GPT-5.2 Codex", source: "curated", family: "gpt-5" },
    { id: "gpt-5.1", label: "GPT-5.1", source: "curated", family: "gpt-5" },
    { id: "gpt-5.1-codex", label: "GPT-5.1 Codex", source: "curated", family: "gpt-5" },
    { id: "gpt-5", label: "GPT-5", source: "curated", family: "gpt-5" },
    { id: "gpt-5-pro", label: "GPT-5 Pro", source: "curated", family: "gpt-5" },
    { id: "gpt-5-mini", label: "GPT-5 mini", source: "curated", family: "gpt-5" },
    { id: "gpt-5-nano", label: "GPT-5 nano", source: "curated", family: "gpt-5" },
    { id: "gpt-5-codex", label: "GPT-5 Codex", source: "curated", family: "gpt-5" },
    { id: "gpt-5-chat-latest", label: "GPT-5 Chat", source: "curated", family: "gpt-5" },
    { id: "o3", label: "o3", source: "curated", family: "o-series" },
    { id: "o3-mini", label: "o3 mini", source: "curated", family: "o-series" },
    { id: "o4-mini", label: "o4 mini", source: "curated", family: "o-series" },
    { id: "o1", label: "o1", source: "curated", family: "o-series" },
    { id: "o1-pro", label: "o1 pro", source: "curated", family: "o-series" },
    { id: "gpt-4.1", label: "GPT-4.1", source: "curated", family: "gpt-4.1" },
    { id: "gpt-4.1-mini", label: "GPT-4.1 mini", source: "curated", family: "gpt-4.1" },
    { id: "gpt-4.1-nano", label: "GPT-4.1 nano", source: "curated", family: "gpt-4.1" },
    { id: "gpt-4o", label: "GPT-4o", source: "curated", family: "gpt-4o" },
    { id: "gpt-4o-mini", label: "GPT-4o mini", source: "curated", family: "gpt-4o" },
    { id: "chatgpt-4o-latest", label: "ChatGPT-4o latest", source: "curated", family: "gpt-4o" },
    { id: "gpt-4-turbo", label: "GPT-4 Turbo", source: "curated", family: "gpt-4" },
  ],
  // Anthropic: 2026-07 live probe. Snapshot ids retire; live GET /v1/models merges.
  anthropic: [
    { id: "claude-sonnet-5", label: "Claude Sonnet 5", source: "curated", family: "sonnet" },
    { id: "claude-fable-5", label: "Claude Fable 5", source: "curated", family: "fable" },
    { id: "claude-opus-4-8", label: "Claude Opus 4.8", source: "curated", family: "opus" },
    { id: "claude-opus-4-7", label: "Claude Opus 4.7", source: "curated", family: "opus" },
    { id: "claude-opus-4-6", label: "Claude Opus 4.6", source: "curated", family: "opus" },
    { id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", source: "curated", family: "sonnet" },
    { id: "claude-opus-4-5-20251101", label: "Claude Opus 4.5", source: "curated", family: "opus" },
    { id: "claude-opus-4-5", label: "Claude Opus 4.5 (alias)", source: "curated", family: "opus" },
    { id: "claude-opus-4-1-20250805", label: "Claude Opus 4.1", source: "curated", family: "opus" },
    { id: "claude-sonnet-4-5-20250929", label: "Claude Sonnet 4.5", source: "curated", family: "sonnet" },
    { id: "claude-sonnet-4-5", label: "Claude Sonnet 4.5 (alias)", source: "curated", family: "sonnet" },
    { id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5", source: "curated", family: "haiku" },
    { id: "claude-haiku-4-5", label: "Claude Haiku 4.5 (alias)", source: "curated", family: "haiku" },
  ],
  gemini: [
    { id: "gemini-2.5-pro", label: "Gemini 2.5 Pro", source: "curated", family: "pro" },
    { id: "gemini-2.5-flash", label: "Gemini 2.5 Flash", source: "curated", family: "flash" },
    { id: "gemini-2.5-flash-lite", label: "Gemini 2.5 Flash Lite", source: "curated", family: "flash" },
    { id: "gemini-2.0-flash", label: "Gemini 2.0 Flash", source: "curated", family: "flash" },
    { id: "gemini-2.0-flash-lite", label: "Gemini 2.0 Flash Lite", source: "curated", family: "flash" },
    { id: "gemini-2.0-pro-exp", label: "Gemini 2.0 Pro (exp)", source: "curated", family: "pro" },
    { id: "gemini-1.5-pro", label: "Gemini 1.5 Pro", source: "curated", family: "pro" },
    { id: "gemini-1.5-flash", label: "Gemini 1.5 Flash", source: "curated", family: "flash" },
    { id: "gemini-1.5-flash-8b", label: "Gemini 1.5 Flash 8B", source: "curated", family: "flash" },
  ],
  // Grok: 2026-07 live xAI list (chat models). Image/video models omitted from curated.
  grok: [
    { id: "grok-4.5", label: "Grok 4.5", source: "curated", family: "grok-4" },
    { id: "grok-4.3", label: "Grok 4.3", source: "curated", family: "grok-4" },
    { id: "grok-4.20-0309-reasoning", label: "Grok 4.20 Reasoning", source: "curated", family: "grok-4" },
    { id: "grok-4.20-0309-non-reasoning", label: "Grok 4.20", source: "curated", family: "grok-4" },
    { id: "grok-4.20-multi-agent-0309", label: "Grok 4.20 Multi-Agent", source: "curated", family: "grok-4" },
    { id: "grok-4", label: "Grok 4", source: "curated", family: "grok-4" },
    { id: "grok-4-0709", label: "Grok 4 (0709)", source: "curated", family: "grok-4" },
    { id: "grok-4-fast-reasoning", label: "Grok 4 Fast Reasoning", source: "curated", family: "grok-4" },
    { id: "grok-4-fast-non-reasoning", label: "Grok 4 Fast", source: "curated", family: "grok-4" },
    { id: "grok-3", label: "Grok 3", source: "curated", family: "grok-3" },
    { id: "grok-3-mini", label: "Grok 3 Mini", source: "curated", family: "grok-3" },
    { id: "grok-3-mini-fast", label: "Grok 3 Mini Fast", source: "curated", family: "grok-3" },
    { id: "grok-3-fast", label: "Grok 3 Fast", source: "curated", family: "grok-3" },
  ],
};

export function curatedModelsFor(provider: ProviderId): ModelInfo[] {
  return [...(CURATED[provider] || [])];
}

function mergeModels(curated: ModelInfo[], live: ModelInfo[]): ModelInfo[] {
  const byId = new Map<string, ModelInfo>();
  for (const m of curated) byId.set(m.id, m);
  for (const m of live) {
    // live wins for label/source
    byId.set(m.id, { ...byId.get(m.id), ...m, source: "live" });
  }
  // Live-first so newly shipped provider models appear at the top of the dropdown.
  // Curated-only ids (aliases, friendly labels) append after.
  const out: ModelInfo[] = [];
  const seen = new Set<string>();
  if (live.length > 0) {
    for (const m of live) {
      const hit = byId.get(m.id);
      if (hit && !seen.has(m.id)) {
        out.push(hit);
        seen.add(m.id);
      }
    }
    for (const m of curated) {
      if (!seen.has(m.id) && byId.has(m.id)) {
        out.push(byId.get(m.id)!);
        seen.add(m.id);
      }
    }
  } else {
    for (const m of curated) {
      const hit = byId.get(m.id);
      if (hit) out.push(hit);
    }
  }
  return out;
}

/** Drop any live ids that don't belong to this provider (safety). */
function filterForProvider(
  provider: ProviderId,
  models: ModelInfo[]
): ModelInfo[] {
  return models.filter((m) => modelBelongsToProvider(provider, m.id));
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
      if (/^(gpt-|o[1-9]|chatgpt-)/i.test(id)) return true;
      return false;
    })
    .filter(
      (id) =>
        !/instruct|realtime|audio|tts|whisper|embedding|moderation|dall-e|babbage|davinci|curie|ada|transcribe|search|image/i.test(
          id
        )
    );
  // Newest-looking ids first (numeric-aware reverse)
  ids.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }));
  return ids
    .slice(0, 120)
    .map((id) => ({ id, label: id, source: "live" as const }));
}

async function fetchGeminiModels(apiKey: string): Promise<ModelInfo[]> {
  const url = `https://generativelanguage.googleapis.com/v1beta/models?key=${encodeURIComponent(apiKey)}`;
  const res = await fetch(url, { signal: AbortSignal.timeout(12_000) });
  if (!res.ok) throw new Error(`gemini models ${res.status}`);
  const data = (await res.json()) as {
    models?: Array<{
      name?: string;
      displayName?: string;
      supportedGenerationMethods?: string[];
    }>;
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
  return out.slice(0, 100);
}

async function fetchGrokModels(apiKey: string): Promise<ModelInfo[]> {
  const res = await fetch("https://api.x.ai/v1/models", {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(12_000),
  });
  if (!res.ok) throw new Error(`grok models ${res.status}`);
  const data = (await res.json()) as { data?: Array<{ id?: string }> };
  // Prefer chat/text models; deprioritize pure image/video generators in the list
  const ids = (data.data || [])
    .map((x) => x.id || "")
    .filter((id) => id && /grok/i.test(id));
  ids.sort((a, b) => {
    const aImg = /imagine|image|video/i.test(a) ? 1 : 0;
    const bImg = /imagine|image|video/i.test(b) ? 1 : 0;
    if (aImg !== bImg) return aImg - bImg;
    return b.localeCompare(a, undefined, { numeric: true });
  });
  return ids
    .slice(0, 60)
    .map((id) => ({ id, label: id, source: "live" as const }));
}

/** Anthropic model list (GET /v1/models): snapshot ids change; prefer live when key present. */
async function fetchAnthropicModels(apiKey: string): Promise<ModelInfo[]> {
  const res = await fetch("https://api.anthropic.com/v1/models?limit=100", {
    headers: {
      "x-api-key": apiKey,
      "anthropic-version": "2023-06-01",
    },
    signal: AbortSignal.timeout(12_000),
  });
  if (!res.ok) throw new Error(`anthropic models ${res.status}`);
  const data = (await res.json()) as {
    data?: Array<{ id?: string; display_name?: string; displayName?: string }>;
  };
  const out: ModelInfo[] = [];
  for (const x of data.data || []) {
    const id = (x.id || "").trim();
    if (!id || !/claude/i.test(id)) continue;
    out.push({
      id,
      label: x.display_name || x.displayName || id,
      source: "live",
    });
  }
  return out.slice(0, 80);
}

/**
 * List models for a provider. Live refresh uses the user's BYOK key when provided.
 * Falls back to curated catalog on any failure.
 * Always returns only models for that provider.
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
        models: filterForProvider(
          provider,
          mergeModels(curated, hit.models)
        ),
        default_model: def,
        live: true,
      };
    }
  }

  let live: ModelInfo[] = [];
  let usedLive = false;
  // Always try live when a BYOK key is present. Cache (above) already short-circuits
  // non-refresh calls. Previously `refresh: false` skipped live entirely, so the
  // desktop /providers?models=1 path only ever showed the stale curated list.
  if (opts.apiKey) {
    try {
      if (provider === "openai") live = await fetchOpenAiModels(opts.apiKey);
      else if (provider === "anthropic")
        live = await fetchAnthropicModels(opts.apiKey);
      else if (provider === "gemini") live = await fetchGeminiModels(opts.apiKey);
      else if (provider === "grok") live = await fetchGrokModels(opts.apiKey);
      if (live.length > 0) {
        live = filterForProvider(provider, live);
        liveCache.set(cacheKey, { at: Date.now(), models: live });
        usedLive = true;
      }
    } catch {
      /* curated fallback */
    }
  }

  return {
    models: filterForProvider(provider, mergeModels(curated, live)),
    default_model: def,
    live: usedLive,
  };
}

/**
 * Anthropic retires dated snapshot ids. Map known dead ids to a current equivalent
 * so sticky/portal prefs don't 404 with the cryptic "model: <id>" error.
 */
const ANTHROPIC_RETIRED_ALIASES: Record<string, string> = {
  "claude-opus-4-20250514": "claude-opus-4-5-20251101",
  "claude-opus-4": "claude-opus-4-5-20251101",
  "claude-opus-4-0": "claude-opus-4-5-20251101",
  "claude-opus-4-0-20250514": "claude-opus-4-5-20251101",
  "claude-4-opus-20250514": "claude-opus-4-5-20251101",
  "claude-sonnet-4-20250514": "claude-sonnet-4-5-20250929",
  "claude-sonnet-4": "claude-sonnet-4-5-20250929",
  "claude-sonnet-4-0": "claude-sonnet-4-5-20250929",
  "claude-sonnet-4-0-20250514": "claude-sonnet-4-5-20250929",
  "claude-3-7-sonnet-20250219": "claude-sonnet-4-5-20250929",
  "claude-3-5-sonnet-20241022": "claude-sonnet-4-5-20250929",
  "claude-3-5-sonnet-latest": "claude-sonnet-4-5-20250929",
  "claude-3-5-haiku-20241022": "claude-haiku-4-5-20251001",
  "claude-3-5-haiku-latest": "claude-haiku-4-5-20251001",
  "claude-3-opus-20240229": "claude-opus-4-1-20250805",
};

/** Resolve model id for a provider (Anthropic retired-id remap; others pass-through). */
export function resolveProviderModelId(
  provider: string,
  modelId: string | null | undefined
): string {
  const raw = (modelId || "").trim();
  if (!raw) return raw;
  if (provider.toLowerCase() !== "anthropic") return raw;
  return ANTHROPIC_RETIRED_ALIASES[raw] || raw;
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
      if (typeof v === "string" && v.trim()) {
        // Drop cross-provider pollution (e.g. gpt-* saved under grok)
        if (modelBelongsToProvider(k, v)) out[k] = v.trim();
      }
    }
    return out;
  } catch {
    return {};
  }
}

export function serializePreferredModels(
  map: Record<string, string>
): string {
  const clean: Record<string, string> = {};
  for (const [k, v] of Object.entries(map)) {
    if (typeof v === "string" && v.trim() && modelBelongsToProvider(k, v)) {
      clean[k] = v.trim();
    }
  }
  return JSON.stringify(clean);
}

/** Resolve model for a request: explicit → user preferred → provider default. */
export function resolveModelForRequest(opts: {
  provider: ProviderId;
  requested?: string | null;
  preferredModels?: Record<string, string> | null;
}): string {
  if (opts.requested && opts.requested.trim()) {
    const req = opts.requested.trim();
    // If client sends a foreign model for this provider, ignore and fall through
    if (modelBelongsToProvider(opts.provider, req)) {
      return resolveProviderModelId(opts.provider, req);
    }
  }
  const pref = opts.preferredModels?.[opts.provider];
  if (pref && pref.trim() && modelBelongsToProvider(opts.provider, pref)) {
    return resolveProviderModelId(opts.provider, pref.trim());
  }
  return defaultModelFor(opts.provider);
}
