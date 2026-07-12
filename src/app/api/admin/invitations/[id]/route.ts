import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireAdmin } from "@/lib/auth";
import { revokeInvitation } from "@/lib/invitations";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

export async function DELETE(
  req: NextRequest,
  ctx: { params: Promise<{ id: string }> }
) {
  try {
    const admin = await requireAdmin();
    const { id } = await ctx.params;
    await revokeInvitation(id);
    await writeAudit({
      action: "settings.update",
      userId: admin.id,
      ip: getClientIpFromHeaders(req.headers),
      meta: { kind: "invitation_revoked", inviteId: id },
    });
    return NextResponse.json({ ok: true });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    const msg = err instanceof Error ? err.message : "Revoke failed";
    return NextResponse.json({ error: msg }, { status: 400 });
  }
}
