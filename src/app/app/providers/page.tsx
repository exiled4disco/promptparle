import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { listProviderCredentials } from "@/lib/providers";
import { PROVIDERS } from "@/lib/constants";
import { ProvidersClient } from "./ProvidersClient";

export const metadata = { title: "Providers" };

export default async function ProvidersPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const credentials = await listProviderCredentials(user.id);

  return (
    <div className="grid gap-6">
      <div>
        <h1 className="page-title">AI providers</h1>
        <p className="page-sub">
          Store provider API keys encrypted. PromptParle uses them when
          forwarding optimized prompts. Keys are never shown again after save.
        </p>
      </div>
      <ProvidersClient
        providers={[...PROVIDERS]}
        credentials={credentials.map((c) => ({
          ...c,
          createdAt: c.createdAt.toISOString(),
          lastUsedAt: c.lastUsedAt?.toISOString() ?? null,
        }))}
      />
    </div>
  );
}
