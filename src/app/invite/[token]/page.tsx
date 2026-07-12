import Link from "next/link";
import { redirect } from "next/navigation";
import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { InviteAcceptForm } from "./InviteAcceptForm";
import { getSessionUser } from "@/lib/auth";
import { getInvitationByRawToken, maskEmail } from "@/lib/invitations";

export const metadata = { title: "Accept invitation" };

export default async function InvitePage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const user = await getSessionUser();
  if (user) redirect("/app");

  const { token } = await params;
  const inv = await getInvitationByRawToken(token);

  let error: string | null = null;
  let email: string | null = null;
  if (!inv) {
    error = "Invalid invitation link.";
  } else if (inv.status === "revoked") {
    error = "This invitation was revoked. Contact your administrator.";
  } else if (inv.status === "accepted" || inv.status === "redeemed") {
    error = "This invitation was already used. Please sign in.";
  } else if (inv.expiresAt < new Date()) {
    error = "This invitation has expired. Ask your administrator for a new one.";
  } else {
    email = inv.email;
  }

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Complete your account</h1>
          <p className="page-sub">
            You were invited to PromptParle. This is{" "}
            <strong className="text-[var(--text)]">not a login</strong>; create
            your password below. You&apos;ll get install steps by email.
          </p>
          <div className="mt-6">
            {error ? (
              <div className="grid gap-4">
                <div className="alert alert-error">{error}</div>
                <Link href="/login" className="btn btn-primary w-full text-center">
                  Go to sign in
                </Link>
              </div>
            ) : (
              <InviteAcceptForm
                token={token}
                email={email!}
                emailMasked={maskEmail(email!)}
              />
            )}
          </div>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
