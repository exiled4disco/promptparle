/**
 * Multi-provider agent chat (one completion step with native tools).
 * OpenAI + Grok: chat/completions tools.
 * Anthropic: messages + tools → tool_use.
 * Gemini: functionDeclarations + functionCall.
 */

import type {
  AgentChatRequest,
  AgentChatResponse,
  AgentMessage,
  AgentToolCall,
  AgentToolDefinition,
} from "./agent-types";
import type { ProviderId } from "../constants";

function asString(v: unknown): string {
  if (v == null) return "";
  if (typeof v === "string") return v;
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

function openAiCompatibleEndpoint(provider: ProviderId): string {
  if (provider === "grok") return "https://api.x.ai/v1/chat/completions";
  return "https://api.openai.com/v1/chat/completions";
}

function isOpenAiReasoningModel(model: string): boolean {
  const m = (model || "").toLowerCase();
  return /(^|\/)(o[1-9]([\w.-]*)?|gpt-5([\w.-]*)?)/.test(m);
}

async function completeOpenAiCompatible(
  provider: ProviderId,
  req: AgentChatRequest
): Promise<AgentChatResponse> {
  const maxOut = req.maxOutputTokens ?? 4096;
  const reasoning =
    provider === "openai" && isOpenAiReasoningModel(req.model);
  const body: Record<string, unknown> = {
    model: req.model,
    messages: req.messages.map((m) => {
      const row: Record<string, unknown> = { role: m.role };
      if (m.content != null) row.content = m.content;
      if (m.name) row.name = m.name;
      if (m.tool_call_id) row.tool_call_id = m.tool_call_id;
      if (m.tool_calls?.length) row.tool_calls = m.tool_calls;
      return row;
    }),
  };
  if (provider === "openai") {
    body.max_completion_tokens = maxOut;
    if (!reasoning) body.temperature = req.temperature ?? 0.2;
  } else {
    // Grok / other OpenAI-compatible: classic max_tokens
    body.temperature = req.temperature ?? 0.2;
    body.max_tokens = maxOut;
  }
  if (req.tools?.length) {
    body.tools = req.tools;
    body.tool_choice = req.toolChoice || "auto";
  }

  const res = await fetch(openAiCompatibleEndpoint(provider), {
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
      data?.error?.message || data?.error || `${provider} error ${res.status}`;
    throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
  }

  const choice = data?.choices?.[0] || {};
  const msg = choice?.message || {};
  const toolCalls: AgentToolCall[] = Array.isArray(msg.tool_calls)
    ? msg.tool_calls.map(
        (tc: {
          id?: string;
          type?: string;
          function?: { name?: string; arguments?: string };
        }) => ({
          id: tc.id || `call_${Math.random().toString(36).slice(2, 10)}`,
          type: "function" as const,
          function: {
            name: tc.function?.name || "",
            arguments:
              typeof tc.function?.arguments === "string"
                ? tc.function.arguments
                : asString(tc.function?.arguments || "{}"),
          },
        })
      )
    : [];

  const content =
    msg.content == null
      ? null
      : typeof msg.content === "string"
        ? msg.content
        : asString(msg.content);

  const usage = data?.usage || {};
  return {
    message: {
      role: "assistant",
      content,
      tool_calls: toolCalls.length ? toolCalls : undefined,
    },
    model: data?.model || req.model,
    finishReason: choice?.finish_reason,
    providerRequestId: data?.id,
    rawUsage: {
      inputTokens: usage.prompt_tokens,
      outputTokens: usage.completion_tokens,
      cacheReadTokens:
        usage.prompt_tokens_details?.cached_tokens ?? usage.cached_tokens,
    },
    raw: data,
  };
}

function toAnthropicTools(tools: AgentToolDefinition[] | undefined) {
  if (!tools?.length) return undefined;
  return tools.map((t) => ({
    name: t.function.name,
    description: t.function.description || "",
    input_schema: t.function.parameters || {
      type: "object",
      properties: {},
    },
  }));
}

function toAnthropicMessages(messages: AgentMessage[]) {
  // Anthropic: system separate; tool results are user content blocks
  const out: Array<{ role: "user" | "assistant"; content: unknown }> = [];
  let system = "";

  for (const m of messages) {
    if (m.role === "system") {
      system += (system ? "\n\n" : "") + (m.content || "");
      continue;
    }
    if (m.role === "user") {
      out.push({ role: "user", content: m.content || "" });
      continue;
    }
    if (m.role === "assistant") {
      const blocks: unknown[] = [];
      if (m.content) blocks.push({ type: "text", text: m.content });
      if (m.tool_calls?.length) {
        for (const tc of m.tool_calls) {
          let input: unknown = {};
          try {
            input = JSON.parse(tc.function.arguments || "{}");
          } catch {
            input = { raw: tc.function.arguments };
          }
          blocks.push({
            type: "tool_use",
            id: tc.id,
            name: tc.function.name,
            input,
          });
        }
      }
      out.push({
        role: "assistant",
        content: blocks.length ? blocks : m.content || "",
      });
      continue;
    }
    if (m.role === "tool") {
      // Merge consecutive tool results into one user message when possible
      const block = {
        type: "tool_result",
        tool_use_id: m.tool_call_id || "",
        content: m.content || "",
      };
      const last = out[out.length - 1];
      if (
        last &&
        last.role === "user" &&
        Array.isArray(last.content) &&
        last.content.length &&
        (last.content[0] as { type?: string }).type === "tool_result"
      ) {
        (last.content as unknown[]).push(block);
      } else {
        out.push({ role: "user", content: [block] });
      }
    }
  }

  return { system, messages: out };
}

async function completeAnthropic(
  req: AgentChatRequest
): Promise<AgentChatResponse> {
  const { system, messages } = toAnthropicMessages(req.messages);
  const body: Record<string, unknown> = {
    model: req.model,
    max_tokens: req.maxOutputTokens ?? 4096,
    temperature: req.temperature ?? 0.2,
    messages,
  };
  if (system) body.system = system;
  const tools = toAnthropicTools(req.tools);
  if (tools?.length) {
    body.tools = tools;
    body.tool_choice =
      req.toolChoice === "none"
        ? { type: "none" }
        : req.toolChoice === "required"
          ? { type: "any" }
          : { type: "auto" };
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
      data?.error?.message || data?.error || `Anthropic error ${res.status}`;
    let msg = typeof raw === "string" ? raw : JSON.stringify(raw);
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
  const textParts: string[] = [];
  const toolCalls: AgentToolCall[] = [];
  for (const b of blocks) {
    if (b.type === "text") textParts.push(b.text || "");
    if (b.type === "tool_use") {
      toolCalls.push({
        id: b.id || `toolu_${Math.random().toString(36).slice(2, 10)}`,
        type: "function",
        function: {
          name: b.name || "",
          arguments: asString(b.input ?? {}),
        },
      });
    }
  }

  const usage = data?.usage || {};
  return {
    message: {
      role: "assistant",
      content: textParts.join("\n") || null,
      tool_calls: toolCalls.length ? toolCalls : undefined,
    },
    model: data?.model || req.model,
    finishReason: data?.stop_reason,
    providerRequestId: data?.id,
    rawUsage: {
      inputTokens: usage.input_tokens,
      outputTokens: usage.output_tokens,
      cacheReadTokens: usage.cache_read_input_tokens,
      cacheWriteTokens: usage.cache_creation_input_tokens,
    },
    raw: data,
  };
}

function toGeminiTools(tools: AgentToolDefinition[] | undefined) {
  if (!tools?.length) return undefined;
  return [
    {
      function_declarations: tools.map((t) => ({
        name: t.function.name,
        description: t.function.description || "",
        parameters: t.function.parameters || {
          type: "object",
          properties: {},
        },
      })),
    },
  ];
}

function toGeminiContents(messages: AgentMessage[]) {
  const systemParts: string[] = [];
  const contents: Array<{ role: string; parts: unknown[] }> = [];

  for (const m of messages) {
    if (m.role === "system") {
      systemParts.push(m.content || "");
      continue;
    }
    if (m.role === "user") {
      contents.push({ role: "user", parts: [{ text: m.content || "" }] });
      continue;
    }
    if (m.role === "assistant") {
      const parts: unknown[] = [];
      if (m.content) parts.push({ text: m.content });
      if (m.tool_calls?.length) {
        for (const tc of m.tool_calls) {
          let args: unknown = {};
          try {
            args = JSON.parse(tc.function.arguments || "{}");
          } catch {
            args = { raw: tc.function.arguments };
          }
          parts.push({
            functionCall: { name: tc.function.name, args },
          });
        }
      }
      contents.push({
        role: "model",
        parts: parts.length ? parts : [{ text: m.content || "" }],
      });
      continue;
    }
    if (m.role === "tool") {
      let response: unknown = m.content || "";
      try {
        response = JSON.parse(m.content || "");
      } catch {
        response = { result: m.content || "" };
      }
      // Gemini wants functionResponse name; we store name on message when possible
      const name = m.name || "tool";
      contents.push({
        role: "user",
        parts: [
          {
            functionResponse: {
              name,
              response:
                typeof response === "object" && response
                  ? response
                  : { result: response },
            },
          },
        ],
      });
    }
  }

  return {
    systemInstruction: systemParts.length
      ? { parts: [{ text: systemParts.join("\n\n") }] }
      : undefined,
    contents,
  };
}

async function completeGemini(
  req: AgentChatRequest
): Promise<AgentChatResponse> {
  const model = req.model || "gemini-2.0-flash";
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(
    model
  )}:generateContent?key=${encodeURIComponent(req.apiKey)}`;

  const { systemInstruction, contents } = toGeminiContents(req.messages);
  const payload: Record<string, unknown> = {
    contents,
    generationConfig: {
      temperature: req.temperature ?? 0.2,
      maxOutputTokens: req.maxOutputTokens ?? 4096,
    },
  };
  if (systemInstruction) payload.systemInstruction = systemInstruction;
  const tools = toGeminiTools(req.tools);
  if (tools) {
    payload.tools = tools;
    payload.tool_config = {
      function_calling_config: {
        mode:
          req.toolChoice === "none"
            ? "NONE"
            : req.toolChoice === "required"
              ? "ANY"
              : "AUTO",
      },
    };
  }

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) {
    const msg =
      data?.error?.message || data?.error || `Gemini error ${res.status}`;
    throw new Error(typeof msg === "string" ? msg : JSON.stringify(msg));
  }

  const parts = data?.candidates?.[0]?.content?.parts || [];
  const textParts: string[] = [];
  const toolCalls: AgentToolCall[] = [];
  for (const p of parts) {
    if (p.text) textParts.push(p.text);
    if (p.functionCall?.name) {
      toolCalls.push({
        id: `gem_${Math.random().toString(36).slice(2, 10)}`,
        type: "function",
        function: {
          name: p.functionCall.name,
          arguments: asString(p.functionCall.args ?? {}),
        },
      });
    }
  }

  return {
    message: {
      role: "assistant",
      content: textParts.join("\n") || null,
      tool_calls: toolCalls.length ? toolCalls : undefined,
    },
    model,
    finishReason: data?.candidates?.[0]?.finishReason,
    rawUsage: {
      inputTokens: data?.usageMetadata?.promptTokenCount,
      outputTokens: data?.usageMetadata?.candidatesTokenCount,
      cacheReadTokens: data?.usageMetadata?.cachedContentTokenCount,
    },
    raw: data,
  };
}

export async function completeAgentChat(
  provider: ProviderId,
  req: AgentChatRequest
): Promise<AgentChatResponse> {
  switch (provider) {
    case "openai":
    case "grok":
      return completeOpenAiCompatible(provider, req);
    case "anthropic":
      return completeAnthropic(req);
    case "gemini":
      return completeGemini(req);
    default:
      throw new Error(`Agent chat not supported for provider: ${provider}`);
  }
}
