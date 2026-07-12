export type ProductScreenshot = {
  id: string;
  /** Base path under /screenshots without extension */
  src: string;
  title: string;
  caption: string;
  group: "desktop" | "portal";
};

/** Public product screenshots, desktop client only (web-optimized under /public/screenshots). */
export const PRODUCT_SCREENSHOTS: ProductScreenshot[] = [
  {
    id: "desktop-live-savings",
    src: "/screenshots/desktop-live-savings",
    title: "Live savings line",
    caption:
      "Real desktop turn: attached user guide → executive summary. ~100k → ~14k tokens (−86%), dial 3/5, Grok. Example, not a guarantee — noisy packs save more than clean prose.",
    group: "desktop",
  },
  {
    id: "desktop-chat",
    src: "/screenshots/desktop-chat",
    title: "Desktop chat",
    caption:
      "Local chat on your PC. Dial, tools, and models stay under your control.",
    group: "desktop",
  },
  {
    id: "desktop-ssh",
    src: "/screenshots/desktop-ssh",
    title: "SSH & workspace",
    caption:
      "Connect remote hosts and work folders without shipping credentials to the cloud.",
    group: "desktop",
  },
  {
    id: "desktop-activity-log",
    src: "/screenshots/desktop-activity-log",
    title: "Activity log",
    caption:
      "Operational stream for updates, tools, and workspace events, not chat history.",
    group: "desktop",
  },
  {
    id: "desktop-usage-savings",
    src: "/screenshots/desktop-usage-savings",
    title: "Usage & savings",
    caption:
      "Same proof strip after each turn: before/after tokens, estimated $, model, and dial.",
    group: "desktop",
  },
];
