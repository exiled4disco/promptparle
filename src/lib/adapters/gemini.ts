import type { AdapterRequest, AdapterResponse, ProviderAdapter } from "./types";

export const geminiAdapter: ProviderAdapter = {
  id: "gemini",
  async complete(req: AdapterRequest): Promise<AdapterResponse> {
    const model = req.model || "gemini-2.0-flash";
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
      model
    )}:generateContent?key=${encodeURIComponent(req.apiKey)}`;

    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [
          {
            role: "user",
            parts: [{ text: req.prompt }],
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

    const parts = data?.candidates?.[0]?.content?.parts || [];
    const text = parts
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
