import type { MetadataRoute } from "next";
import { siteUrl } from "@/lib/site";

export default function robots(): MetadataRoute.Robots {
  const base = siteUrl();
  return {
    rules: [
      {
        userAgent: "*",
        allow: [
          "/",
          "/faq",
          "/install",
          "/pricing",
          "/trust",
          "/examples",
          "/llms.txt",
          "/llms-full.txt",
        ],
        disallow: [
          "/app/",
          "/api/",
          "/invite/",
          "/verify-email",
          "/reset-password",
          "/forgot-password",
          "/login",
          "/register",
          // Legacy route: now redirects to /register (open signup)
          "/request-invite",
        ],
      },
    ],
    sitemap: `${base}/sitemap.xml`,
  };
}

// Note: major search + AI crawlers (Googlebot, GPTBot, ClaudeBot, PerplexityBot,
// Bingbot, Applebot, Amazonbot, etc.) inherit User-agent: * rules above.
