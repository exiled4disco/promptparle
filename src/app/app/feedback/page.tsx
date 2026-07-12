import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { FeedbackInbox } from "./FeedbackInbox";

export const metadata = { title: "Messages" };

export default async function FeedbackAdminPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.isAdmin) redirect("/app");

  return (
    <div className="grid gap-3">
      <PageHeader
        title="Messages"
        description="Contact messages, bug reports, and suggestions from the site and desktop client. Open one to read it and reply — your reply is emailed to the sender. You also get an email on each new submission."
      />
      <FeedbackInbox />
    </div>
  );
}
