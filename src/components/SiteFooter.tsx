import Link from "next/link";
import { GitHubSponsorButton } from "@/components/GitHubSponsors";
import { FloatingContact } from "@/components/FloatingContact";
import { Logo } from "@/components/Logo";
import {
  COPYRIGHT_LINE,
  TAGLINE,
  TRADEMARK_LINE,
} from "@/lib/constants";
import { SUPPORT } from "@/lib/pricing";

type SiteFooterProps = {
  /** Show logo + tagline row (landing). Auth/app can use compact legal-only. */
  showBrand?: boolean;
  className?: string;
  /**
   * Hide the floating "Contact us" button. Set true in the portal (logged-in
   * users have the FeedbackButton) and on the /contact page itself. Default:
   * the button shows on all public marketing + auth pages.
   */
  hideContact?: boolean;
};

export function SiteFooter({
  showBrand = true,
  className = "",
  hideContact = false,
}: SiteFooterProps) {
  return (
    <>
      {/* Floating Contact-us button on public pages. Suppressed in the portal
          (FeedbackButton there) and on /contact itself via hideContact. */}
      {hideContact ? null : <FloatingContact />}
    <footer
      className={`border-t border-[var(--border)] py-8 ${className}`.trim()}
    >
      <div className="container flex flex-col items-center gap-3 text-center text-sm text-[var(--text-dim)]">
        {showBrand ? (
          <div className="flex w-full flex-col items-center justify-between gap-3 md:flex-row md:text-left">
            <Logo size="sm" />
            <p className="md:text-right">{TAGLINE}</p>
          </div>
        ) : null}
        <div className="flex flex-wrap items-center justify-center gap-x-3 gap-y-1 text-xs">
          <Link href="/#product" className="hover:text-[var(--text)]">
            Product
          </Link>
          <span aria-hidden>·</span>
          <Link href="/examples" className="hover:text-[var(--text)]">
            Examples
          </Link>
          <span aria-hidden>·</span>
          <Link href="/pricing" className="hover:text-[var(--text)]">
            Pricing
          </Link>
          <span aria-hidden>·</span>
          <Link href="/trust" className="hover:text-[var(--text)]">
            Trust
          </Link>
          <span aria-hidden>·</span>
          <Link href="/faq" className="hover:text-[var(--text)]">
            FAQ
          </Link>
          <span aria-hidden>·</span>
          <Link href="/contact" className="hover:text-[var(--text)]">
            Contact
          </Link>
          <span aria-hidden>·</span>
          <Link href="/install" className="hover:text-[var(--text)]">
            Install
          </Link>
          <span aria-hidden>·</span>
          <Link href="/register" className="hover:text-[var(--text)]">
            Create free account
          </Link>
          <span aria-hidden>·</span>
          <Link href="/llms.txt" className="hover:text-[var(--text)]">
            llms.txt
          </Link>
          <span aria-hidden>·</span>
          <a
            href="https://github.com/exiled4disco/promptparle"
            target="_blank"
            rel="noreferrer"
            className="hover:text-[var(--text)]"
          >
            GitHub
          </a>
          <span aria-hidden>·</span>
          <a
            href={SUPPORT.newsletterHref}
            target="_blank"
            rel="noreferrer"
            className="hover:text-[var(--text)]"
          >
            Newsletter
          </a>
          <span aria-hidden>·</span>
          <a
            href={SUPPORT.href}
            target="_blank"
            rel="noreferrer"
            className="hover:text-[var(--text)]"
          >
            Sponsor
          </a>
        </div>
        <div className="pt-1">
          <GitHubSponsorButton />
        </div>
        <div className="flex w-full flex-col items-center gap-1 text-xs leading-relaxed text-[var(--text-dim)]">
          <p>{COPYRIGHT_LINE}</p>
          <p>{TRADEMARK_LINE}</p>
        </div>
      </div>
    </footer>
    </>
  );
}
