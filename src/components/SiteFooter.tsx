import Link from "next/link";
import { Logo } from "@/components/Logo";
import {
  COPYRIGHT_LINE,
  TAGLINE,
  TRADEMARK_LINE,
} from "@/lib/constants";

type SiteFooterProps = {
  /** Show logo + tagline row (landing). Auth/app can use compact legal-only. */
  showBrand?: boolean;
  className?: string;
};

export function SiteFooter({
  showBrand = true,
  className = "",
}: SiteFooterProps) {
  return (
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
        </div>
        <div className="flex w-full flex-col items-center gap-1 text-xs leading-relaxed text-[var(--text-dim)]">
          <p>{COPYRIGHT_LINE}</p>
          <p>{TRADEMARK_LINE}</p>
        </div>
      </div>
    </footer>
  );
}
