export type AdapterRequest = {
  apiKey: string;
  model: string;
  prompt: string;
  /** optional system-ish framing already baked into prompt for MVP */
  temperature?: number;
  maxOutputTokens?: number;
};

export type AdapterResponse = {
  text: string;
  model: string;
  providerRequestId?: string;
  rawUsage?: {
    inputTokens?: number;
    outputTokens?: number;
  };
};

export type ProviderAdapter = {
  id: string;
  complete(req: AdapterRequest): Promise<AdapterResponse>;
};
