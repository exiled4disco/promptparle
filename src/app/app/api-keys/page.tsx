import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { listApiKeys } from "@/lib/api-keys";
import { ApiKeysClient } from "./ApiKeysClient";

export const metadata = { title: "API Keys" };

export default async function ApiKeysPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const keys = await listApiKeys(user.id);

  return (
    <div className="grid gap-6">
      <div>
        <h1 className="page-title">Desktop API keys</h1>
        <p className="page-sub">
          Generate <span className="mono">pp_live_…</span> keys for PowerShell
          and VS Code. The full key is shown once — only a hash is stored.
        </p>
      </div>
      <ApiKeysClient
        keys={keys.map((k) => ({
          ...k,
          createdAt: k.createdAt.toISOString(),
          lastUsedAt: k.lastUsedAt?.toISOString() ?? null,
          revokedAt: k.revokedAt?.toISOString() ?? null,
        }))}
      />
    </div>
  );
}
