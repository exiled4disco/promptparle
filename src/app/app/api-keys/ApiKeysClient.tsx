"use client";

import { FormEvent, useState } from "react";
import { useRouter } from "next/navigation";
import { CopyButton } from "@/components/CopyButton";
import { formatDate } from "@/lib/format";

type ApiKeyRow = {
  id: string;
  name: string;
  keyPrefix: string;
  scope: string;
  status: string;
  lastUsedAt: string | null;
  createdAt: string;
  revokedAt: string | null;
};

export function ApiKeysClient({ keys: initial }: { keys: ApiKeyRow[] }) {
  const router = useRouter();
  const [keys, setKeys] = useState(initial);
  const [name, setName] = useState("Desktop");
  const [fullKey, setFullKey] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setFullKey(null);
    setLoading(true);
    try {
      const res = await fetch("/api/api-keys", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to create key");
        return;
      }
      setFullKey(data.fullKey);
      setKeys((prev) => [
        {
...data.key,
          lastUsedAt: null,
          revokedAt: null,
        },
...prev,
      ]);
      router.refresh();
    } catch {
      setError("Network error");
    } finally {
      setLoading(false);
    }
  }

  async function onRevoke(id: string) {
    if (!confirm("Revoke this API key? Clients using it will stop working.")) {
      return;
    }
    const res = await fetch(`/api/api-keys/${id}`, { method: "DELETE" });
    if (res.ok) {
      setKeys((prev) =>
        prev.map((k) =>
          k.id === id
            ? {...k, status: "revoked", revokedAt: new Date().toISOString() }
            : k
        )
      );
      router.refresh();
    }
  }

  return (
    <div className="grid gap-6">
      <form onSubmit={onSubmit} className="card grid gap-4 p-6 md:max-w-xl">
        <h2 className="text-lg font-semibold">Create key</h2>
        {error && <div className="alert alert-error">{error}</div>}
        <div className="field">
          <label className="label" htmlFor="name">
            Name
          </label>
          <input
            id="name"
            className="input"
            required
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="Laptop PowerShell"
          />
        </div>
        <button className="btn btn-primary w-fit" disabled={loading}>
          {loading ? "Generating…" : "Generate API key"}
        </button>
      </form>

      {fullKey && (
        <div className="card border-[rgba(52,211,153,0.35)] p-6">
          <h3 className="font-semibold text-[var(--success)]">
            Copy your key now
          </h3>
          <p className="mt-1 text-sm text-[var(--text-muted)]">
            This is the only time the full key will be shown.
          </p>
          <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-center">
            <code className="mono flex-1 break-all rounded-lg border border-[var(--border)] bg-[var(--bg)] px-3 py-3 text-sm">
              {fullKey}
            </code>
            <CopyButton value={fullKey} />
          </div>
          <pre className="mt-4 overflow-x-auto rounded-lg border border-[var(--border)] bg-[var(--bg)] p-4 text-xs text-[var(--text-muted)] mono">
{`Set-PromptParleApiKey -ApiKey "${fullKey}"`}
          </pre>
        </div>
      )}

      <section className="card overflow-hidden">
        <div className="border-b border-[var(--border)] px-6 py-4">
          <h2 className="text-lg font-semibold">Your keys</h2>
        </div>
        {keys.length === 0 ? (
          <p className="p-6 text-sm text-[var(--text-muted)]">
            No desktop API keys yet.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table">
              <thead>
                <tr>
                  <th>Name</th>
                  <th>Prefix</th>
                  <th>Scope</th>
                  <th>Status</th>
                  <th>Created</th>
                  <th>Last used</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {keys.map((k) => (
                  <tr key={k.id}>
                    <td className="font-medium">{k.name}</td>
                    <td className="mono text-[var(--text-muted)]">
                      {k.keyPrefix}…
                    </td>
                    <td>{k.scope}</td>
                    <td>
                      <span
                        className={`badge ${
                          k.status === "active" ? "badge-success" : "badge-warn"
                        }`}
                      >
                        {k.status}
                      </span>
                    </td>
                    <td className="whitespace-nowrap text-[var(--text-muted)]">
                      {formatDate(k.createdAt)}
                    </td>
                    <td className="whitespace-nowrap text-[var(--text-muted)]">
                      {k.lastUsedAt ? formatDate(k.lastUsedAt) : "-"}
                    </td>
                    <td className="text-right">
                      {k.status === "active" && (
                        <button
                          type="button"
                          className="btn btn-danger"
                          onClick={() => onRevoke(k.id)}
                        >
                          Revoke
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
