import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { listActiveDesktopClients } from "@/lib/desktop-clients";
import { PROVIDERS } from "@/lib/constants";
import { curatedModelsFor } from "@/lib/models";
import type { ProviderId } from "@/lib/constants";
import { SettingsForm } from "./SettingsForm";

export const metadata = { title: "Settings" };

export default async function SettingsPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const active = await listActiveDesktopClients(user.id);
  const modelCatalog: Record<
    string,
    Array<{ id: string; label: string; source?: string }>
  > = {};
  for (const p of PROVIDERS.filter((x) => x.enabled)) {
    modelCatalog[p.id] = curatedModelsFor(p.id as ProviderId).map((m) => ({
      id: m.id,
      label: m.label,
      source: m.source,
    }));
  }

  return (
    <div className="grid gap-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="page-title !mb-0.5">Settings</h1>
          <p className="page-sub !mt-0 text-sm">
            Profile, chat models, dial, desktop features, and client seats —
            syncs with the desktop client.
          </p>
        </div>
      </div>
      <SettingsForm
        user={user}
        modelCatalog={modelCatalog}
        activeClients={active.map((c) => ({
          clientId: c.clientId,
          hostname: c.hostname,
          platform: c.platform,
          appVersion: c.appVersion,
          lastSeenAt: c.lastSeenAt,
        }))}
      />
    </div>
  );
}
