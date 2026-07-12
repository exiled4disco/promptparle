import { redirect } from "next/navigation";
import { PageHeader } from "@/components/PageHeader";
import { getSessionUser } from "@/lib/auth";
import { BugTracker } from "./BugTracker";

export const metadata = { title: "Bug tracker" };

export default async function BugTrackerPage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");

  return (
    <div className="grid gap-4">
      <PageHeader
        title="Bug tracker"
        description="Report a bug or suggest a feature, and track the status of what you've submitted. You only see your own reports."
      />
      <BugTracker />
    </div>
  );
}
