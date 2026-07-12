import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { listActiveDesktopClients } from "@/lib/desktop-clients";
import { PROVIDERS } from "@/lib/constants";
import { curatedModelsFor } from "@/lib/models";
import type { ProviderId } from "@/lib/constants";
import { SettingsForm } from "./SettingsForm";
import { ChangePasswordForm } from "@/components/ChangePasswordForm";
import { PageHeader } from "@/components/PageHeader";

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
      <PageHeader
        title="Settings"
        description="Profile, chat models, dial, desktop features, and client seats. Settings sync with the desktop client."
      />
      <ChangePasswordForm hasPassword={user.hasPassword} />
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
