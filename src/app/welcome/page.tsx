import { redirect } from "next/navigation";
import { Logo } from "@/components/Logo";
import { LogoutButton } from "@/components/LogoutButton";
import { getSessionUser } from "@/lib/auth";
import { WelcomeWizard } from "@/components/WelcomeWizard";

export const metadata = { title: "Get started" };

export default async function WelcomePage() {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.emailVerifiedAt) {
    redirect(`/verify-email?email=${encodeURIComponent(user.email)}`);
  }

  return (
    <div className="flex min-h-full flex-col">
      <header className="border-b border-[var(--border)]">
        <div className="container flex items-center justify-between py-3">
          <Logo size="sm" href="/app" />
          <LogoutButton />
        </div>
      </header>
      <main className="container flex-1 py-10">
        <WelcomeWizard userName={user.name} />
      </main>
    </div>
  );
}
