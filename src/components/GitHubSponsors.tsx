import { SUPPORT } from "@/lib/pricing";

type EmbedProps = {
  className?: string;
};

/**
 * Official GitHub Sponsors button (114x32 iframe).
 * Prefer this over a custom CTA when the goal is "open Sponsors checkout".
 */
export function GitHubSponsorButton({ className = "" }: EmbedProps) {
  return (
    <div className={`inline-flex leading-none ${className}`.trim()}>
      <iframe
        src={SUPPORT.buttonEmbedSrc}
        title="Sponsor exiled4disco on GitHub"
        height={32}
        width={114}
        style={{ border: 0, borderRadius: 6 }}
        loading="lazy"
      />
    </div>
  );
}

/**
 * Official GitHub Sponsors card (600x225 iframe). Used on /pricing.
 * Scales down on narrow viewports via max-width + aspect-friendly height.
 */
export function GitHubSponsorCard({ className = "" }: EmbedProps) {
  return (
    <div
      className={`w-full max-w-[600px] overflow-hidden rounded-lg ${className}`.trim()}
    >
      <iframe
        src={SUPPORT.cardEmbedSrc}
        title="Sponsor exiled4disco on GitHub"
        height={225}
        width={600}
        className="max-w-full"
        style={{ border: 0, width: "100%", maxWidth: 600 }}
        loading="lazy"
      />
    </div>
  );
}
