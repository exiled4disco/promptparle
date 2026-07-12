import { redirect } from "next/navigation";
import { Logo } from "@/components/Logo";
import { LogoutButton } from "@/components/LogoutButton";
import { SiteFooter } from "@/components/SiteFooter";
import { AppNav } from "@/components/AppNav";
import { FeedbackButton } from "@/components/FeedbackButton";
import { getSessionUser } from "@/lib/auth";

const NAV = [
  { href: "/app", label: "Dashboard", exact: true },
  { href: "/app/providers", label: "Providers guide" },
  { href: "/app/api-keys", label: "License keys" },
  { href: "/app/usage", label: "Usage" },
  { href: "/app/settings", label: "Settings" },
];

export default async function AppLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const user = await getSessionUser();
  if (!user) redirect("/login");
  if (!user.emailVerifiedAt) {
    redirect(`/verify-email?email=${encodeURIComponent(user.email)}`);
  }

  const nav = user.isAdmin
    ? [
        ...NAV,
        { href: "/app/feedback", label: "Feedback" },
        { href: "/app/accounts", label: "Accounts" },
        { href: "/app/invitations", label: "Invitations" },
      ]
    : NAV;

  return (
    <div className="flex min-h-full flex-col">
      <header className="sticky top-0 z-20 isolate border-b border-[var(--border)] bg-[var(--bg)]">
        <div className="container flex items-center justify-between gap-4 py-3">
          <div className="flex min-w-0 items-center gap-8">
            <Logo size="sm" href="/app" />
            <div className="hidden md:block">
              <AppNav items={nav} variant="desktop" />
            </div>
          </div>
          <div className="flex items-center gap-2 sm:gap-3">
            <div className="hidden text-right sm:block">
              <div className="text-sm font-medium">
                {user.name || user.email}
              </div>
              <div className="text-xs capitalize text-[var(--text-dim)]">
                {user.isAdmin ? "admin · " : ""}
                {user.plan} plan
              </div>
            </div>
            <LogoutButton />
          </div>
        </div>
        <div className="md:hidden">
          <AppNav items={nav} variant="mobile" />
        </div>
      </header>
      <main className="container flex-1 py-8">{children}</main>
      <SiteFooter showBrand={false} className="py-5" />
      {/* Outside header so fixed FAB/modal never get clipped by sticky chrome */}
      <FeedbackButton />
    </div>
  );
}
