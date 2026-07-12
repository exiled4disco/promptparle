import Link from "next/link";
import { formatNumber } from "@/lib/format";
import type { PlanLimits } from "@/lib/plans";

type FreePlanToastProps = {
  limits: Pick<
    PlanLimits,
    "dailyRequests" | "originalChars" | "maxProviders"
  >;
};

/**
 * Permanent bottom-of-viewport toast for free-tier limits.
 * Fixed so it stays visible while scrolling the Usage page.
 */
export function FreePlanToast({ limits }: FreePlanToastProps) {
  return (
    <div
      className="pointer-events-none fixed inset-x-0 bottom-0 z-40 flex justify-center p-3 sm:p-4"
      role="status"
      aria-live="polite"
      aria-label="Free plan limits"
    >
      <div className="pointer-events-auto flex w-full max-w-4xl flex-col gap-3 rounded-2xl border border-[var(--accent)]/40 bg-[rgba(10,14,24,0.94)] px-4 py-3 shadow-[0_12px_40px_rgba(0,0,0,0.55)] backdrop-blur-md sm:flex-row sm:items-center sm:justify-between sm:gap-4 sm:px-5 sm:py-3.5">
        <div className="min-w-0">
          <div className="text-xs font-semibold uppercase tracking-wide text-[var(--accent-strong)]">
            Free plan
          </div>
          <div className="mt-1.5 flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm text-[var(--text)]">
            <span>
              <span className="text-[var(--text-dim)]">Flat price: </span>
              <strong className="font-semibold">$0</strong>
            </span>
            <span className="hidden text-[var(--border-strong)] sm:inline" aria-hidden>
              ·
            </span>
            <span>
              <span className="text-[var(--text-dim)]">Providers: </span>
              <strong className="font-semibold">
                {formatNumber(limits.maxProviders)}
              </strong>
            </span>
            <span className="hidden text-[var(--border-strong)] sm:inline" aria-hidden>
              ·
            </span>
            <span className="text-[var(--text-dim)]">
              Pro from $29.99/mo · Team of 5 $99.99/mo
            </span>
          </div>
        </div>
        <Link
          href="/pricing"
          className="btn btn-primary shrink-0 whitespace-nowrap px-5 py-2.5 text-sm"
        >
          View pricing
        </Link>
      </div>
    </div>
  );
}
