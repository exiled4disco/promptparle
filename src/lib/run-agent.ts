/**
 * One-step agent pass-through: messages + tools → provider → assistant message.
 * No prompt optimization. Desktop owns multi-round tool loop.
 *
 * Portal usage history still stores the request context window (messages + tools)
 * so Before/After is readable — pass-through means After ≈ Before with a header.
 */

import {
  getActiveProviderKey,
  isProviderRoutable,
  isValidProvider,
  touchProviderCredential,
} from "./providers";
import { completeAgentChat } from "./adapters/agent-chat";
import type {
  AgentChatResponse,
  AgentMessage,
  AgentToolDefinition,
} from "./adapters/agent-types";
import type { ProviderId } from "./constants";
import { recordPromptRequest } from "./prompt-request";
import { estimateTokens } from "./tokens";
import {
  parsePreferredModelsJson,
  resolveModelForRequest,
} from "./models";

/** Serialize agent messages (+ optional tools) for portal usage Before/After. */
export function formatAgentContextWindow(
  messages: AgentMessage[],
  tools?: AgentToolDefinition[] | null,
  opts?: { mode?: "request" | "sent"; maxChars?: number }
): string {
  const mode = opts?.mode || "request";
  const maxChars = opts?.maxChars ?? 200_000;
  const parts: string[] = [];

  if (mode === "sent") {
    parts.push(
      "# Sent to provider (agent pass-through — not optimized)",
      "Architecture: 0.22-native-agent. Desktop owns the multi-round tool loop; this row is one model step."
    );
  } else {
    parts.push(
      "# Agent request context window",
      "Architecture: 0.22-native-agent. Full messages for this step (not a stub)."
    );
  }

  if (tools && tools.length > 0) {
    parts.push(`## Tools available (${tools.length})`);
    const limit = 48;
    for (const t of tools.slice(0, limit)) {
      const name = t.function?.name || t.type || "tool";
      const desc = (t.function?.description || "").replace(/\s+/g, " ").trim();
      const short = desc.length > 140 ? desc.slice(0, 137) + "…" : desc;
      parts.push(short ? `- ${name}: ${short}` : `- ${name}`);
    }
    if (tools.length > limit) {
      parts.push(`- … +${tools.length - limit} more tools`);
    }
  }

  parts.push(`## Messages (${messages.length})`);
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i];
    const role = m.role || "unknown";
    let head = `### [${i + 1}] ${role}`;
    if (m.name) head += ` name=${m.name}`;
    if (m.tool_call_id) head += ` tool_call_id=${m.tool_call_id}`;
    parts.push(head);

    if (m.content != null && String(m.content).length > 0) {
      parts.push(String(m.content));
    } else if (!m.tool_calls?.length) {
      parts.push("(empty content)");
    }

    if (m.tool_calls && m.tool_calls.length > 0) {
      for (const tc of m.tool_calls) {
        const args = tc.function?.arguments || "";
        const argsShow =
          args.length > 4000 ? args.slice(0, 4000) + "\n…[tool args truncated]" : args;
        parts.push(
          `tool_call id=${tc.id} name=${tc.function?.name || "?"}\n${argsShow}`
        );
      }
    }
  }

  let text = parts.join("\n\n");
  if (text.length > maxChars) {
    text =
      text.slice(0, Math.max(0, maxChars - 40)) +
      "\n\n…[context window truncated for storage prep]";
  }
  return text;
}

export type RunAgentInput = {
  userId: string;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  provider: string;
  model?: string;
  /** JSON map or object of provider→preferred model (portal user prefs) */
  preferredModels?: string | Record<string, string> | null;
  messages: AgentMessage[];
  tools?: AgentToolDefinition[];
  toolChoice?: "auto" | "none" | "required";
  maxTokens?: number;
  temperature?: number;
  /** Include truncated raw provider body for desktop capture */
  includeRaw?: boolean;
};

export type RunAgentSuccess = {
  ok: true;
  message: AgentMessage;
  model: string;
  finish_reason?: string;
  provider: string;
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    cache_read_tokens?: number;
    cache_write_tokens?: number;
  };
  provider_request_id?: string;
  pass_through: true;
  architecture: "0.22-native-agent";
  raw?: unknown;
};

export type RunAgentFailure = {
  ok: false;
  status: number;
  error: string;
};

export type RunAgentResult = RunAgentSuccess | RunAgentFailure;

export async function runAgentStep(
  input: RunAgentInput
): Promise<RunAgentResult> {
  const provider = input.provider.toLowerCase();
  if (!isValidProvider(provider)) {
    return { ok: false, status: 400, error: "Unknown provider" };
  }
  if (!isProviderRoutable(provider)) {
    return {
      ok: false,
      status: 400,
      error: `Provider '${provider}' is not available for routing yet`,
    };
  }
  if (!Array.isArray(input.messages) || input.messages.length === 0) {
    return { ok: false, status: 400, error: "messages required" };
  }

  const providerId = provider as ProviderId;
  const preferredMap =
    typeof input.preferredModels === "string"
      ? parsePreferredModelsJson(input.preferredModels)
      : input.preferredModels || null;
  const model = resolveModelForRequest({
    provider: providerId,
    requested: input.model,
    preferredModels: preferredMap,
  });

  const cred = await getActiveProviderKey(input.userId, providerId);
  if (!cred) {
    return {
      ok: false,
      status: 400,
      error: `No active ${providerId} API key. Add one under Providers.`,
    };
  }

  // Rough token estimate for usage history (not optimized)
  const estIn = estimateTokens(
    input.messages
      .map((m) => {
        const c = m.content || "";
        const tools = m.tool_calls
          ? m.tool_calls.map((t) => t.function.name + t.function.arguments).join(" ")
          : "";
        return `${m.role} ${c} ${tools}`;
      })
      .join("\n")
  );

  // Portal usage Before/After: real context window (was stubbed as [agent-step] in 0.22.0)
  const contextWindow = formatAgentContextWindow(input.messages, input.tools, {
    mode: "request",
  });
  const sentWindow = formatAgentContextWindow(input.messages, input.tools, {
    mode: "sent",
  });

  let result: AgentChatResponse;
  try {
    result = await completeAgentChat(providerId, {
      apiKey: cred.apiKey,
      model,
      messages: input.messages,
      tools: input.tools,
      toolChoice: input.toolChoice || "auto",
      temperature: input.temperature ?? 0.2,
      maxOutputTokens: input.maxTokens ?? 4096,
    });
    await touchProviderCredential(cred.credentialId);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    try {
      await recordPromptRequest({
        userId: input.userId,
        plan: input.plan,
        retentionPolicy: input.retentionPolicy,
        storePrompts: input.storePrompts,
        provider: providerId,
        model,
        optimizationProfile: "agent-pass-through",
        originalTokens: estIn,
        optimizedTokens: estIn,
        status: "error",
        prompt: contextWindow,
        context: null,
        optimizedPrompt: sentWindow,
        errorMessage: msg,
      });
    } catch {
      /* ignore */
    }
    return { ok: false, status: 502, error: msg };
  }

  const inTok = result.rawUsage?.inputTokens ?? estIn;
  const outTok = result.rawUsage?.outputTokens ?? estimateTokens(result.message.content || "");

  // Append assistant step outcome to After pane so the window is complete for that round
  let afterText = sentWindow;
  try {
    const asst = result.message;
    const bits: string[] = [
      afterText,
      "",
      "## Assistant step result",
      `finish_reason: ${result.finishReason || "unknown"}`,
    ];
    if (asst.content) bits.push(String(asst.content));
    if (asst.tool_calls?.length) {
      for (const tc of asst.tool_calls) {
        const args = tc.function?.arguments || "";
        const argsShow =
          args.length > 4000 ? args.slice(0, 4000) + "\n…[args truncated]" : args;
        bits.push(
          `tool_call id=${tc.id} name=${tc.function?.name || "?"}\n${argsShow}`
        );
      }
    }
    afterText = bits.join("\n");
  } catch {
    /* keep sentWindow */
  }

  try {
    await recordPromptRequest({
      userId: input.userId,
      plan: input.plan,
      retentionPolicy: input.retentionPolicy,
      storePrompts: input.storePrompts,
      provider: providerId,
      model: result.model,
      optimizationProfile: "agent-pass-through",
      originalTokens: inTok,
      optimizedTokens: inTok, // pass-through: no token reduction claimed
      status: "ok",
      prompt: contextWindow,
      context: null,
      optimizedPrompt: afterText,
    });
  } catch {
    /* ignore usage write failures */
  }

  const out: RunAgentSuccess = {
    ok: true,
    message: result.message,
    model: result.model,
    finish_reason: result.finishReason,
    provider: providerId,
    usage: {
      input_tokens: result.rawUsage?.inputTokens,
      output_tokens: result.rawUsage?.outputTokens,
      cache_read_tokens: result.rawUsage?.cacheReadTokens,
      cache_write_tokens: result.rawUsage?.cacheWriteTokens,
    },
    provider_request_id: result.providerRequestId,
    pass_through: true,
    architecture: "0.22-native-agent",
  };

  if (input.includeRaw && result.raw) {
    // Cap raw capture size
    try {
      const s = JSON.stringify(result.raw);
      if (s.length <= 80_000) out.raw = result.raw;
      else out.raw = { truncated: true, bytes: s.length };
    } catch {
      /* skip */
    }
  }

  // silence unused outTok lint if any
  void outTok;
  return out;
}
