import type { AdapterRequest, AdapterResponse, ProviderAdapter } from "./types";

export const openaiAdapter: ProviderAdapter = {
  id: "openai",
  async complete(req: AdapterRequest): Promise<AdapterResponse> {
    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${req.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: req.model,
        messages: [
          {
            role: "user",
            content: req.prompt,
          },
        ],
        temperature: req.temperature ?? 0.2,
        max_tokens: req.maxOutputTokens ?? 4096,
      }),
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg =
        data?.error?.message ||
        data?.error ||
        `OpenAI error ${res.status}`;
      throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
    }

    const text =
      data?.choices?.[0]?.message?.content?.toString?.() ||
      data?.choices?.[0]?.text ||
      "";

    return {
      text,
      model: data?.model || req.model,
      providerRequestId: data?.id,
      rawUsage: {
        inputTokens: data?.usage?.prompt_tokens,
        outputTokens: data?.usage?.completion_tokens,
      },
    };
  },
};
