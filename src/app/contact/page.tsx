import { SiteFooter } from "@/components/SiteFooter";
import { SiteHeader } from "@/components/SiteHeader";
import { ContactForm } from "./ContactForm";

export const metadata = {
  title: "Contact",
  description:
    "Get in touch with the PromptParle team. Questions, feedback, or support — we'll reply to your email.",
  alternates: { canonical: "/contact" },
};

export default function ContactPage() {
  return (
    <div className="flex min-h-full flex-col">
      <SiteHeader />
      <main className="container flex flex-1 items-start justify-center pb-16 pt-8">
        <div className="card w-full max-w-md p-7">
          <h1 className="page-title">Contact us</h1>
          <p className="page-sub">
            Questions, feedback, or need a hand? Send a message and we&apos;ll
            reply to your email. PromptParle is free — no sales pitch.
          </p>
          <div className="mt-6">
            <ContactForm />
          </div>
        </div>
      </main>
      <SiteFooter showBrand={false} hideContact />
    </div>
  );
}
