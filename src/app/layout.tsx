import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

/** Force dark native chrome (scrollbars, form controls) on light OS themes. */
export const viewport: Viewport = {
  colorScheme: "dark",
  themeColor: "#07090f",
};

export const metadata: Metadata = {
  title: {
    default: "PromptParle | Trim the prompt. Keep the signal.",
    template: "%s · PromptParle",
  },
  description:
    "PromptParle is an AI context optimization gateway. Strip bloated tokens, keep flagship models, lower effective cost. Free for everyone; chat on your desktop.",
  metadataBase: new URL(process.env.NEXT_PUBLIC_APP_URL || "https://promptparle.com"),
  applicationName: "PromptParle",
  keywords: [
    "PromptParle",
    "promptparle.com",
    "what is PromptParle",
    "AI context optimization",
    "token savings",
    "reduce AI token cost",
    "BYOK",
    "PowerShell AI client",
    "prompt gateway",
    "flagship model cost control",
  ],
  icons: {
    icon: [
      { url: "/favicon.ico" },
      { url: "/favicon-32.png", sizes: "32x32", type: "image/png" },
      { url: "/logo-192.png", sizes: "192x192", type: "image/png" },
    ],
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180" }],
  },
  alternates: {
    canonical: "/",
  },
  openGraph: {
    title: "PromptParle | Trim the prompt. Keep the signal.",
    description:
      "AI context optimization gateway. Flagship models, lower effective token cost. Desktop chat on your PC.",
    url: "https://promptparle.com",
    siteName: "PromptParle",
    images: [{ url: "/logo.png", width: 512, height: 512, alt: "PromptParle" }],
    type: "website",
    locale: "en_US",
  },
  twitter: {
    card: "summary_large_image",
    title: "PromptParle",
    description:
      "AI context optimization gateway. Flagship models, lower effective token cost.",
    images: ["/logo.png"],
  },
  other: {
    "ai-content": "llms.txt",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-image-preview": "large",
      "max-snippet": -1,
      "max-video-preview": -1,
    },
  },
  verification: process.env.GOOGLE_SITE_VERIFICATION
    ? { google: process.env.GOOGLE_SITE_VERIFICATION }
    : undefined,
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} h-full antialiased`}
      style={{ colorScheme: "dark" }}
    >
      <body className="min-h-full flex flex-col" style={{ colorScheme: "dark" }}>
        {children}
      </body>
    </html>
  );
}
