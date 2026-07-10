import Link from "next/link";

export function Logo({ size = "md" }: { size?: "sm" | "md" | "lg" }) {
  const text =
    size === "lg" ? "text-2xl" : size === "sm" ? "text-base" : "text-lg";
  const mark =
    size === "lg" ? "h-9 w-9 text-sm" : size === "sm" ? "h-7 w-7 text-[10px]" : "h-8 w-8 text-xs";

  return (
    <Link href="/" className="inline-flex items-center gap-2.5">
      <span
        className={`${mark} inline-flex items-center justify-center rounded-xl bg-gradient-to-br from-[#5b8cff] to-[#34d399] font-bold text-white shadow-[0_8px_20px_rgba(91,140,255,0.35)]`}
      >
        PP
      </span>
      <span className={`${text} font-semibold tracking-tight`}>
        Prompt<span className="text-[#93b4ff]">Parle</span>
      </span>
    </Link>
  );
}
