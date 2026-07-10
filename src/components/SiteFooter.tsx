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
            <p className="md:text-right">promptparle.com · {TAGLINE}</p>
          </div>
        ) : null}
        <div className="flex w-full flex-col items-center gap-1 text-xs leading-relaxed text-[var(--text-dim)]">
          <p>{COPYRIGHT_LINE}</p>
          <p>{TRADEMARK_LINE}</p>
        </div>
      </div>
    </footer>
  );
}
