import { redirect } from "next/navigation";
import { getSessionUser } from "@/lib/auth";
import { SettingsForm } from "./SettingsForm";

export const metadata = { title: "Settings" };

export default async function SettingsPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  return (
    <div className="grid gap-6">
      <div>
        <h1 className="page-title">Settings</h1>
        <p className="page-sub">
          Account profile and prompt retention controls.
        </p>
      </div>
      <SettingsForm user={user} />
    </div>
  );
}
