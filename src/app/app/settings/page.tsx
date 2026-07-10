import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { listActiveDesktopClients } from "@/lib/desktop-clients";
import { SettingsForm } from "./SettingsForm";

export const metadata = { title: "Settings" };

export default async function SettingsPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  const active = await listActiveDesktopClients(user.id);

  return (
    <div className="grid gap-6">
      <div>
        <h1 className="page-title">Settings</h1>
        <p className="page-sub">
          Account profile, desktop project connections, and client seats.
        </p>
      </div>
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
