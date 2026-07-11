export const APP_NAME = "PromptParle";
export const TAGLINE = "Trim the prompt. Keep the signal.";
export const SESSION_COOKIE = "pp_session";
export const SESSION_DAYS = 30;

/** Legal notices shown in website and product footers. */
export const COPYRIGHT_YEAR = 2026;
export const COPYRIGHT_LINE = `© ${COPYRIGHT_YEAR} PromptParle. All rights reserved.`;
export const TRADEMARK_LINE =
  "PromptParle™ and the PromptParle logo are trademarks of PromptParle.";

/**
 * AI providers users can attach keys for.
 * `routing` = supported by POST /v1/prompt adapters.
 */
export const PROVIDERS = [
  {
    id: "openai",
    name: "OpenAI",
    description: "GPT-5, GPT-4.1, GPT-4o, o-series, and other OpenAI models",
    docsUrl: "https://platform.openai.com/api-keys",
    placeholder: "sk-...",
    enabled: true,
    routing: true,
    defaultModel: "gpt-4o",
  },
  {
    id: "anthropic",
    name: "Anthropic Claude",
    description: "Claude Opus/Sonnet/Haiku 4.x and 3.x models",
    docsUrl: "https://console.anthropic.com/settings/keys",
    placeholder: "sk-ant-...",
    enabled: true,
    routing: true,
    defaultModel: "claude-sonnet-4-20250514",
  },
  {
    id: "gemini",
    name: "Google Gemini",
    description: "Gemini 2.5 / 2.0 models via Google AI Studio",
    docsUrl: "https://aistudio.google.com/apikey",
    placeholder: "AIza...",
    enabled: true,
    routing: true,
    defaultModel: "gemini-2.5-flash",
  },
  {
    id: "grok",
    name: "xAI Grok",
    description: "Grok 4 / 3 / 2 models via the xAI API",
    docsUrl: "https://console.x.ai/",
    placeholder: "xai-...",
    enabled: true,
    routing: true,
    defaultModel: "grok-3",
  },
] as const;

export type ProviderId = (typeof PROVIDERS)[number]["id"];

export const OPTIMIZATION_PROFILES = [
  {
    id: "general",
    name: "General",
    description: "Clean filler, preserve intent",
  },
  {
    id: "developer",
    name: "Developer",
    description: "Code, errors, stack traces",
  },
  {
    id: "security-review",
    name: "Security Review",
    description: "IPs, logs, rules, indicators",
  },
  {
    id: "log-analysis",
    name: "Log Analysis",
    description: "Deduplicate, keep outliers",
  },
  {
    id: "documentation",
    name: "Documentation",
    description: "Query-aware section keep, outline, densify prose",
  },
  {
    id: "executive-summary",
    name: "Executive Summary",
    description: "Aggressive doc compress — outline + high-signal excerpts",
  },
] as const;

export type OptimizationProfileId = (typeof OPTIMIZATION_PROFILES)[number]["id"];

export const RETENTION_OPTIONS = [
  { id: "none", label: "Do not store prompt content (tokens only)" },
  { id: "7d", label: "7 days" },
  { id: "30d", label: "30 days" },
] as const;

export function getProviderMeta(id: string) {
  return PROVIDERS.find((p) => p.id === id);
}
