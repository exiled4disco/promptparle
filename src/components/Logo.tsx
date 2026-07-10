import Image from "next/image";
import Link from "next/link";

const SIZES = {
  sm: { box: 28, text: "text-base", gap: "gap-2" },
  md: { box: 34, text: "text-lg", gap: "gap-2.5" },
  lg: { box: 44, text: "text-2xl", gap: "gap-3" },
} as const;

export function Logo({
  size = "md",
  href = "/",
  showWordmark = true,
}: {
  size?: "sm" | "md" | "lg";
  href?: string | null;
  showWordmark?: boolean;
}) {
  const s = SIZES[size];
  const mark = (
    <Image
      src="/logo.png"
      alt=""
      width={s.box}
      height={s.box}
      className="rounded-[22%] shadow-[0_6px_18px_rgba(91,140,255,0.35)]"
      priority={size !== "sm"}
    />
  );

  const wordmark = showWordmark ? (
    <span className={`${s.text} font-semibold tracking-tight`}>
      Prompt<span className="text-[#93b4ff]">Parle</span>
    </span>
  ) : (
    <span className="sr-only">PromptParle</span>
  );

  const inner = (
    <span className={`inline-flex items-center ${s.gap}`}>
      {mark}
      {wordmark}
    </span>
  );

  if (href === null) return inner;
  return (
    <Link href={href} className="inline-flex items-center">
      {inner}
    </Link>
  );
}
