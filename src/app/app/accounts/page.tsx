import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { AccountsClient } from "./AccountsClient";

export const metadata = { title: "Accounts" };

export default async function AccountsPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.isAdmin) redirect("/app");

  return (
    <div className="grid gap-3">
      <PageHeader
        title="Accounts"
        description="Registered users with last IP/country. Disable blocks login and API keys; delete removes the account permanently."
      />
      <AccountsClient />
    </div>
  );
}
