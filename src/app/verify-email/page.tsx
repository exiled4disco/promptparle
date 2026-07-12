import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { VerifyEmailClient } from "./VerifyEmailClient";

export const metadata = { title: "Verify email" };

export default async function VerifyEmailPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const token = typeof params.token === "string" ? params.token : "";
  const email = typeof params.email === "string" ? params.email : "";
  const error = typeof params.error === "string" ? params.error : "";
  const sent = params.sent === "1" || params.sent === "true";
  const notice = typeof params.notice === "string" ? params.notice : "";

  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Verify your email</h1>
          <p className="page-sub">
            Confirm your address to activate your PromptParle account.
          </p>
          <div className="mt-6">
            <VerifyEmailClient
              token={token}
              email={email}
              initialError={error}
              justSent={sent}
              notice={notice}
            />
          </div>
        </div>
      </main>
      <SiteFooter showBrand={false} />
    </div>
  );
}
