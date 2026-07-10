import type { Metadata } from "next";
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

export const metadata: Metadata = {
  title: {
    default: "PromptParle — Trim the prompt. Keep the signal.",
    template: "%s · PromptParle",
  },
  description:
    "AI context optimization gateway. Cleaner prompts, better answers, less token waste — from PowerShell and VS Code.",
  metadataBase: new URL(process.env.NEXT_PUBLIC_APP_URL || "https://promptparle.com"),
  applicationName: "PromptParle",
  icons: {
    icon: [
      { url: "/favicon.ico" },
      { url: "/favicon-32.png", sizes: "32x32", type: "image/png" },
      { url: "/logo-192.png", sizes: "192x192", type: "image/png" },
    ],
    apple: [{ url: "/apple-touch-icon.png", sizes: "180x180" }],
  },
  openGraph: {
    title: "PromptParle — Trim the prompt. Keep the signal.",
    description:
      "AI context optimization gateway. Cleaner prompts, better answers, less token waste.",
    url: "/",
    siteName: "PromptParle",
    images: [{ url: "/logo.png", width: 512, height: 512, alt: "PromptParle" }],
    type: "website",
  },
  twitter: {
    card: "summary",
    title: "PromptParle",
    description: "Trim the prompt. Keep the signal.",
    images: ["/logo.png"],
  },
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
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
