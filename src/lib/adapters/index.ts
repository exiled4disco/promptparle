import type { ProviderId } from "../constants";
import type { ProviderAdapter } from "./types";
import { openaiAdapter } from "./openai";
import { anthropicAdapter } from "./anthropic";
import { geminiAdapter } from "./gemini";
import { grokAdapter } from "./grok";

const ADAPTERS: Record<ProviderId, ProviderAdapter> = {
  openai: openaiAdapter,
  anthropic: anthropicAdapter,
  gemini: geminiAdapter,
  grok: grokAdapter,
};

export function getAdapter(provider: ProviderId): ProviderAdapter {
  const adapter = ADAPTERS[provider];
  if (!adapter) {
    throw new Error(`No adapter for provider: ${provider}`);
  }
  return adapter;
}

export type { AdapterRequest, AdapterResponse } from "./types";
