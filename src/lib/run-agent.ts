/**
 * One-step agent pass-through: messages + tools → provider → assistant message.
 * No prompt optimization. Desktop owns multi-round tool loop.
 */

import {
  defaultModelFor,
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

export type RunAgentInput = {
  userId: string;
  plan: string;
  retentionPolicy: string;
  storePrompts: boolean;
  provider: string;
  model?: string;
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
  const model = input.model || defaultModelFor(providerId);

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
        prompt: "[agent-step]",
        context: null,
        optimizedPrompt: "[agent-pass-through]",
        errorMessage: msg,
      });
    } catch {
      /* ignore */
    }
    return { ok: false, status: 502, error: msg };
  }

  const inTok = result.rawUsage?.inputTokens ?? estIn;
  const outTok = result.rawUsage?.outputTokens ?? estimateTokens(result.message.content || "");

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
      optimizedTokens: inTok,
      status: "ok",
      prompt: "[agent-step]",
      context: null,
      optimizedPrompt: "[agent-pass-through — no optimize]",
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
