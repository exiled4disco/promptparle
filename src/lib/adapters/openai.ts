import type { AdapterRequest, AdapterResponse, ProviderAdapter } from "./types";
import { normalizeAdapterImages } from "./types";
import { combineSystemMessage } from "../system-framing";

/** o1/o3/o4/gpt-5 reject max_tokens; use max_completion_tokens (and omit temperature). */
function isOpenAiReasoningModel(model: string): boolean {
  const m = (model || "").toLowerCase();
  return /(^|\/)(o[1-9]([\w.-]*)?|gpt-5([\w.-]*)?)/.test(m);
}

export const openaiAdapter: ProviderAdapter = {
  id: "openai",
  async complete(req: AdapterRequest): Promise<AdapterResponse> {
    const images = normalizeAdapterImages(req.images);
    let content:
      | string
      | Array<
          | { type: "text"; text: string }
          | { type: "image_url"; image_url: { url: string } }
        >;

    if (images.length === 0) {
      content = req.prompt;
    } else {
      content = [
        { type: "text", text: req.prompt },
        ...images.map((img) => ({
          type: "image_url" as const,
          image_url: {
            url: `data:${img.mediaType};base64,${img.dataBase64}`,
          },
        })),
      ];
    }

    const messages: Array<{ role: string; content: typeof content | string }> =
      [];
    const system = combineSystemMessage(req.system || "", req.runtime);
    if (system) {
      messages.push({ role: "system", content: system });
    }
    messages.push({ role: "user", content });

    const maxOut = req.maxOutputTokens ?? 4096;
    const reasoning = isOpenAiReasoningModel(req.model);
    const body: Record<string, unknown> = {
      model: req.model,
      messages,
      // OpenAI: max_tokens rejected on o-series / gpt-5 — use max_completion_tokens
      max_completion_tokens: maxOut,
    };
    if (!reasoning) {
      body.temperature = req.temperature ?? 0.2;
    }

    const res = await fetch("https://api.openai.com/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${req.apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
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

    const usage = data?.usage || {};
    return {
      text,
      model: data?.model || req.model,
      providerRequestId: data?.id,
      rawUsage: {
        inputTokens: usage.prompt_tokens,
        outputTokens: usage.completion_tokens,
        cacheReadTokens:
          usage.prompt_tokens_details?.cached_tokens ??
          usage.cached_tokens,
      },
    };
  },
};
