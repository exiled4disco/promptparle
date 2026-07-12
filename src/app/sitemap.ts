import type { MetadataRoute } from "next";
import { siteUrl } from "@/lib/site";

export default function sitemap(): MetadataRoute.Sitemap {
  const base = siteUrl();
  const now = new Date();

  return [
    {
      url: `${base}/`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 1,
    },
    {
      url: `${base}/faq`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 0.95,
    },
    {
      url: `${base}/install`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 0.9,
    },
    {
      url: `${base}/request-invite`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.8,
    },
    {
      url: `${base}/pricing`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 0.9,
    },
    {
      url: `${base}/trust`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 0.9,
    },
    {
      url: `${base}/examples`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 0.85,
    },
    {
      url: `${base}/llms.txt`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.4,
    },
    {
      url: `${base}/llms-full.txt`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.3,
    },
  ];
}
