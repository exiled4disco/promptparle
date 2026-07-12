import { NextResponse } from "next/server";

/**
 * Self-serve registration is disabled. Use invitation links only.
 * POST kept so old clients get a clear error instead of silent failure.
 */
export async function POST() {
  return NextResponse.json(
    {
      error:
        "Open registration is disabled. You need an invitation link from a PromptParle administrator.",
      code: "invite_required",
    },
    { status: 403 }
  );
}
