import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
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
      <PageHeader
        title="Desktop license keys"
        description={
          <>
            Generate <span className="mono">pp_live_…</span> license keys for the
            desktop client. This is not an OpenAI/Claude key, set model keys on
            your PC (⋯ → Providers). Full value shown once; only a hash is stored.
          </>
        }
      />
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
