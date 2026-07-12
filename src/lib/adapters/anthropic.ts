import type { AdapterRequest, AdapterResponse, ProviderAdapter } from "./types";
import { normalizeAdapterImages } from "./types";

export const anthropicAdapter: ProviderAdapter = {
  id: "anthropic",
  async complete(req: AdapterRequest): Promise<AdapterResponse> {
    const images = normalizeAdapterImages(req.images);
    const content: Array<
      | { type: "text"; text: string }
      | {
          type: "image";
          source: {
            type: "base64";
            media_type: string;
            data: string;
          };
        }
    > = [];

    // Anthropic: images first, then text (common pattern)
    for (const img of images) {
      content.push({
        type: "image",
        source: {
          type: "base64",
          media_type: img.mediaType,
          data: img.dataBase64,
        },
      });
    }
    content.push({ type: "text", text: req.prompt });

    // Static product brief is cacheable; runtime note changes every turn.
    type SysBlock = {
      type: "text";
      text: string;
      cache_control?: { type: "ephemeral" };
    };
    const systemBlocks: SysBlock[] = [];
    const staticSys = (req.system || "").trim();
    const runtime = (req.runtime || "").trim();
    if (staticSys) {
      systemBlocks.push({
        type: "text",
        text: staticSys,
        cache_control: { type: "ephemeral" },
      });
    }
    if (runtime) {
      systemBlocks.push({ type: "text", text: `[RT] ${runtime}` });
    }

    const body: Record<string, unknown> = {
      model: req.model,
      max_tokens: req.maxOutputTokens ?? 4096,
      messages: [
        {
          role: "user",
          content: images.length === 0 ? req.prompt : content,
        },
      ],
      temperature: req.temperature ?? 0.2,
    };
    if (systemBlocks.length === 1 && !runtime && staticSys) {
      // Single cached system string is fine; keep array form for cache_control
      body.system = systemBlocks;
    } else if (systemBlocks.length > 0) {
      body.system = systemBlocks;
    }

    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": req.apiKey,
        "anthropic-version": "2023-06-01",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });

    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const raw =
        data?.error?.message ||
        data?.error ||
        `Anthropic error ${res.status}`;
      let msg = typeof raw === "string" ? raw : JSON.stringify(raw);
      // Anthropic not_found often returns only "model: <id>": make it actionable
      if (/^model:\s*/i.test(msg) || (res.status === 404 && /model/i.test(msg))) {
        const id = msg.replace(/^model:\s*/i, "").trim() || req.model;
        msg =
          `Anthropic model not found: ${id}. That snapshot may be retired. ` +
          `Pick a current id (e.g. claude-sonnet-4-5, claude-opus-4-6) from the Model list.`;
      } else if (data?.error?.type) {
        msg = `${data.error.type}: ${msg}`;
      }
      throw new Error(msg);
    }

    const blocks = Array.isArray(data?.content) ? data.content : [];
    const text = blocks
      .filter((b: { type?: string }) => b.type === "text")
      .map((b: { text?: string }) => b.text || "")
      .join("\n");

    const usage = data?.usage || {};
    return {
      text,
      model: data?.model || req.model,
      providerRequestId: data?.id,
      rawUsage: {
        inputTokens: usage.input_tokens,
        outputTokens: usage.output_tokens,
        cacheReadTokens: usage.cache_read_input_tokens,
        cacheWriteTokens: usage.cache_creation_input_tokens,
      },
    };
  },
};
