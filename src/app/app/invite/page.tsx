import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { InviteFriends } from "./InviteFriends";

export const metadata = { title: "Invite a friend" };

export default async function InvitePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  return (
    <div className="grid gap-3">
      <PageHeader
        title="Invite a friend"
        description="PromptParle is free. Send someone an invite and they'll get an email with a link to create their account. You can see the ones you've sent below."
      />
      <InviteFriends />
    </div>
  );
}
