import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { InvitationsClient } from "./InvitationsClient";

export const metadata = { title: "Invitations" };

export default async function InvitationsPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.isAdmin) redirect("/app");

  return (
    <div className="grid gap-3">
      <PageHeader
        title="Invitation manager"
        description="Send one-time invites. Customers complete a form (not login), receive an install code by email, then install the desktop client."
      />
      <InvitationsClient />
    </div>
  );
}
