/**
 * Unified multi-provider agent chat types (OpenAI-shaped wire format).
 * Desktop owns the tool loop; portal is one model step pass-through.
 */

export type AgentToolCall = {
  id: string;
  type: "function";
  function: {
    name: string;
    arguments: string; // JSON string
  };
};

export type AgentMessage = {
  role: "system" | "user" | "assistant" | "tool";
  content?: string | null;
  name?: string;
  tool_call_id?: string;
  tool_calls?: AgentToolCall[];
};

export type AgentToolDefinition = {
  type: "function";
  function: {
    name: string;
    description?: string;
    parameters?: Record<string, unknown>;
  };
};

export type AgentChatRequest = {
  apiKey: string;
  model: string;
  messages: AgentMessage[];
  tools?: AgentToolDefinition[];
  toolChoice?: "auto" | "none" | "required";
  temperature?: number;
  maxOutputTokens?: number;
};

export type AgentChatResponse = {
  message: AgentMessage;
  model: string;
  finishReason?: string;
  providerRequestId?: string;
  rawUsage?: {
    inputTokens?: number;
    outputTokens?: number;
    cacheReadTokens?: number;
    cacheWriteTokens?: number;
  };
  /** Provider raw body for capture (truncated by caller if needed) */
  raw?: unknown;
};
