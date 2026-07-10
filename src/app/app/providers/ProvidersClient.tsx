"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";

type ProviderMeta = {
  id: string;
  name: string;
  description: string;
  docsUrl: string;
  placeholder: string;
  enabled: boolean;
};

type Credential = {
  id: string;
  provider: string;
  label: string | null;
  keyLastFour: string;
  status: string;
  createdAt: string;
  lastUsedAt: string | null;
};

export function ProvidersClient({
  providers,
  credentials: initial,
}: {
  providers: ProviderMeta[];
  credentials: Credential[];
}) {
  const router = useRouter();
  const [credentials, setCredentials] = useState(initial);
  const [provider, setProvider] = useState(
    providers.find((p) => p.enabled)?.id || "openai"
  );
  const [apiKey, setApiKey] = useState("");
  const [label, setLabel] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  const selected = providers.find((p) => p.id === provider);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    setLoading(true);
    try {
      const res = await fetch("/api/providers", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ provider, apiKey, label: label || undefined }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to save key");
        return;
      }
      setApiKey("");
      setLabel("");
      setSuccess(`${selected?.name || provider} key saved and encrypted.`);
      setCredentials((prev) => {
        const rest = prev.filter((c) => c.provider !== data.credential.provider);
        return [
          {
            ...data.credential,
            createdAt: data.credential.createdAt,
            lastUsedAt: data.credential.lastUsedAt,
          },
          ...rest,
        ];
      });
      router.refresh();
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  async function onDelete(id: string) {
    if (!confirm("Delete this provider key permanently?")) return;
    const res = await fetch(`/api/providers/${id}`, { method: "DELETE" });
    if (res.ok) {
      setCredentials((prev) => prev.filter((c) => c.id !== id));
      router.refresh();
    }
  }

  return (
    <div className="grid gap-6 lg:grid-cols-5">
      <form onSubmit={onSubmit} className="card grid gap-4 p-6 lg:col-span-2">
        <h2 className="text-lg font-semibold">Add provider key</h2>
        {error && <div className="alert alert-error">{error}</div>}
        {success && <div className="alert alert-success">{success}</div>}

        <div className="field">
          <label className="label" htmlFor="provider">
            Provider
          </label>
          <select
            id="provider"
            className="select"
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
          >
            {providers.map((p) => (
              <option key={p.id} value={p.id} disabled={!p.enabled}>
                {p.name}
                {!p.enabled ? " (coming soon)" : ""}
              </option>
            ))}
          </select>
          {selected && (
            <p className="text-xs text-[var(--text-dim)]">
              {selected.description}.{" "}
              <a
                href={selected.docsUrl}
                target="_blank"
                rel="noreferrer"
                className="text-[#93b4ff] hover:underline"
              >
                Get a key
              </a>
            </p>
          )}
        </div>

        <div className="field">
          <label className="label" htmlFor="apiKey">
            API key
          </label>
          <input
            id="apiKey"
            className="input mono"
            type="password"
            required
            minLength={8}
            value={apiKey}
            onChange={(e) => setApiKey(e.target.value)}
            placeholder={selected?.placeholder || "sk-..."}
            autoComplete="off"
          />
        </div>

        <div className="field">
          <label className="label" htmlFor="label">
            Label <span className="dim">(optional)</span>
          </label>
          <input
            id="label"
            className="input"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
            placeholder="Production OpenAI"
          />
        </div>

        <button className="btn btn-primary" disabled={loading || !selected?.enabled}>
          {loading ? "Encrypting & saving…" : "Save encrypted key"}
        </button>

        <p className="text-xs leading-relaxed text-[var(--text-dim)]">
          Keys are encrypted with AES-256-GCM before storage. Only the last four
          characters are shown in the portal. Full keys never appear in logs.
        </p>
      </form>

      <section className="card overflow-hidden lg:col-span-3">
        <div className="border-b border-[var(--border)] px-6 py-4">
          <h2 className="text-lg font-semibold">Configured providers</h2>
        </div>
        {credentials.length === 0 ? (
          <p className="p-6 text-sm text-[var(--text-muted)]">
            No provider keys yet. Add OpenAI or Anthropic to get started.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table">
              <thead>
                <tr>
                  <th>Provider</th>
                  <th>Label</th>
                  <th>Key</th>
                  <th>Status</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {credentials.map((c) => {
                  const meta = providers.find((p) => p.id === c.provider);
                  return (
                    <tr key={c.id}>
                      <td className="font-medium">{meta?.name || c.provider}</td>
                      <td className="text-[var(--text-muted)]">
                        {c.label || "—"}
                      </td>
                      <td className="mono text-[var(--text-muted)]">
                        ••••{c.keyLastFour}
                      </td>
                      <td>
                        <span
                          className={`badge ${
                            c.status === "active"
                              ? "badge-success"
                              : "badge-warn"
                          }`}
                        >
                          {c.status}
                        </span>
                      </td>
                      <td className="text-right">
                        <button
                          type="button"
                          className="btn btn-danger"
                          onClick={() => onDelete(c.id)}
                        >
                          Delete
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
