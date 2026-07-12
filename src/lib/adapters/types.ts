export type AdapterImage = {
  /** MIME type, e.g. image/png, image/jpeg, image/webp, image/gif */
  mediaType: string;
  /** Raw base64 payload (no data: prefix) */
  dataBase64: string;
  name?: string;
};

export type AdapterRequest = {
  apiKey: string;
  model: string;
  /** User-turn content (optimized). Do not bake product system brief here. */
  prompt: string;
  /**
   * Native system message (product brief). Prefer this over baking into prompt.
   * Providers that support prompt cache put cache_control on this static block.
   */
  system?: string;
  /**
   * Per-turn runtime note (tools/prep). Not cached: changes every call.
   * Anthropic: second system block without cache_control.
   * Others: appended to system string.
   */
  runtime?: string;
  temperature?: number;
  maxOutputTokens?: number;
  /** Optional vision images (BYOK multimodal). Text is still optimized separately. */
  images?: AdapterImage[];
};

export type AdapterResponse = {
  text: string;
  model: string;
  providerRequestId?: string;
  rawUsage?: {
    inputTokens?: number;
    outputTokens?: number;
    /** Provider-reported cache hits (Anthropic/OpenAI when available) */
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
  };
};

export type ProviderAdapter = {
  id: string;
  complete(req: AdapterRequest): Promise<AdapterResponse>;
};

export function normalizeAdapterImages(
  images: AdapterImage[] | undefined
): AdapterImage[] {
  if (!images || images.length === 0) return [];
  const allowed = new Set([
    "image/png",
    "image/jpeg",
    "image/jpg",
    "image/webp",
    "image/gif",
  ]);
  const out: AdapterImage[] = [];
  for (const img of images) {
    if (!img?.dataBase64 || !img.mediaType) continue;
    let mediaType = img.mediaType.toLowerCase().trim();
    if (mediaType === "image/jpg") mediaType = "image/jpeg";
    if (!allowed.has(mediaType)) continue;
    // strip accidental data-url prefix
    let data = img.dataBase64.trim();
    const m = /^data:([^;]+);base64,(.+)$/i.exec(data);
    if (m) {
      mediaType = m[1].toLowerCase() === "image/jpg" ? "image/jpeg" : m[1].toLowerCase();
      data = m[2];
    }
    if (!data || data.length > 8_000_000) continue; // ~6MB binary cap
    out.push({
      mediaType,
      dataBase64: data,
      name: img.name,
    });
    if (out.length >= 6) break;
  }
  return out;
}
