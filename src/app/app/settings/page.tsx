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
    <div className="grid gap-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h1 className="page-title !mb-0.5">Settings</h1>
          <p className="page-sub !mt-0 text-sm">
            Profile, API IP allowlist, desktop features, and client seats — one
            screen.
          </p>
        </div>
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
