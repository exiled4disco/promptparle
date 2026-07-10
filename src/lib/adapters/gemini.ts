import type { AdapterRequest, AdapterResponse, ProviderAdapter } from "./types";
import { normalizeAdapterImages } from "./types";

export const geminiAdapter: ProviderAdapter = {
  id: "gemini",
  async complete(req: AdapterRequest): Promise<AdapterResponse> {
    const model = req.model || "gemini-2.0-flash";
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
      model
    )}:generateContent?key=${encodeURIComponent(req.apiKey)}`;

    const images = normalizeAdapterImages(req.images);
    const parts: Array<
      | { text: string }
      | { inline_data: { mime_type: string; data: string } }
    > = [{ text: req.prompt }];

    for (const img of images) {
      parts.push({
        inline_data: {
          mime_type: img.mediaType,
          data: img.dataBase64,
        },
      });
    }

    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts,
          },
        ],
        generationConfig: {
          temperature: req.temperature ?? 0.2,
          maxOutputTokens: req.maxOutputTokens ?? 4096,
        },
      }),
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg =
        data?.error?.message ||
        data?.error ||
        `Gemini error ${res.status}`;
      throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
    }

    const outParts = data?.candidates?.[0]?.content?.parts || [];
    const text = outParts
      .map((p: { text?: string }) => p.text || "")
      .join("\n");

    return {
      text,
      model,
      rawUsage: {
        inputTokens: data?.usageMetadata?.promptTokenCount,
        outputTokens: data?.usageMetadata?.candidatesTokenCount,
      },
    };
  },
};
