import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { FeedbackInbox } from "./FeedbackInbox";

export const metadata = { title: "Feedback" };

export default async function FeedbackAdminPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.isAdmin) redirect("/app");

  return (
    <div className="grid gap-3">
      <PageHeader
        title="Feedback inbox"
        description="Bug reports and suggestions from the portal and desktop client. You also get an email on each new submission."
      />
      <FeedbackInbox />
    </div>
  );
}
