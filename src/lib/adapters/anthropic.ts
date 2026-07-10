import type { AdapterRequest, AdapterResponse, ProviderAdapter } from "./types";

export const anthropicAdapter: ProviderAdapter = {
  id: "anthropic",
  async complete(req: AdapterRequest): Promise<AdapterResponse> {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": req.apiKey,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: req.model,
        max_tokens: req.maxOutputTokens ?? 4096,
        messages: [
          {
            role: "user",
            content: req.prompt,
          },
        ],
        temperature: req.temperature ?? 0.2,
      }),
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg =
        data?.error?.message ||
        data?.error ||
        `Anthropic error ${res.status}`;
      throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
    }

    const blocks = Array.isArray(data?.content) ? data.content : [];
    const text = blocks
      .filter((b: { type?: string }) => b.type === "text")
      .map((b: { text?: string }) => b.text || "")
      .join("\n");

    return {
      text,
      model: data?.model || req.model,
      providerRequestId: data?.id,
      rawUsage: {
        inputTokens: data?.usage?.input_tokens,
        outputTokens: data?.usage?.output_tokens,
      },
    };
  },
};
