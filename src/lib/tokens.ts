/**
 * Rough token estimate (no tokenizer dep).
 * ~4 chars/token for English/code mix — good enough for reduction stats.
 */
export function estimateTokens(text: string): number {
  if (!text) return 0;
  return Math.max(1, Math.ceil(text.length / 4));
}
