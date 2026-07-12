import { NextRequest, NextResponse } from "next/server";
import { getInvitationByRawToken, maskEmail } from "@/lib/invitations";

/** Public: resolve invite token for the accept form (no secrets). */
export async function GET(req: NextRequest) {
  const token = req.nextUrl.searchParams.get("token") || "";
  const inv = await getInvitationByRawToken(token);
  if (!inv) {
    return NextResponse.json({ error: "Invalid invitation link" }, { status: 404 });
  }
  if (inv.status === "revoked") {
    return NextResponse.json({ error: "This invitation was revoked" }, { status: 410 });
  }
  if (inv.status === "accepted" || inv.status === "redeemed") {
    return NextResponse.json(
      { error: "This invitation was already used. Please sign in." },
      { status: 409 }
    );
  }
  if (inv.expiresAt < new Date()) {
    return NextResponse.json({ error: "This invitation has expired" }, { status: 410 });
  }
  return NextResponse.json({
    ok: true,
    email: inv.email,
    emailMasked: maskEmail(inv.email),
    expiresAt: inv.expiresAt,
  });
}
