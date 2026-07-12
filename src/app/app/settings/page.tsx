import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { listActiveDesktopClients } from "@/lib/desktop-clients";
import { SettingsForm } from "./SettingsForm";
import { ChangePasswordForm } from "@/components/ChangePasswordForm";
import { PageHeader } from "@/components/PageHeader";

export const metadata = { title: "Settings" };

export default async function SettingsPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const active = await listActiveDesktopClients(user.id);

  return (
    <div className="grid gap-3">
      <PageHeader
        title="Settings"
        description="Profile, usage retention, API IP allowlist, and desktop client seats. Chat models, dial, and project connections are set in the desktop client."
      />
      <ChangePasswordForm hasPassword={user.hasPassword} />
      <SettingsForm
        user={user}
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
