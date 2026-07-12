import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { redeemInviteCode } from "@/lib/invitations";

const schema = z.object({
  code: z.string().min(6).max(32),
});

/** Authenticated desktop: mark invitation redeemed after API key works. */
export async function POST(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "code required" }, { status: 400 });
    }
    const result = await redeemInviteCode({
      code: parsed.data.code,
      userId: auth.user.id,
    });
    if (!result.ok) {
      return NextResponse.json({ error: result.error }, { status: 400 });
    }
    return NextResponse.json({ ok: true, redeemed: true });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("invite redeem", err);
    return NextResponse.json({ error: "Redeem failed" }, { status: 500 });
  }
}
