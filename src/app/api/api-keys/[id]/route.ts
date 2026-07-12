import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { revokeApiKey } from "@/lib/api-keys";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

export async function DELETE(
  req: NextRequest,
  context: { params: Promise<{ id: string }> }
) {
  try {
    const user = await requireUser();
    const { id } = await context.params;
    await revokeApiKey(user.id, id);
    await writeAudit({
      action: "apikey.revoke",
      userId: user.id,
      ip: getClientIpFromHeaders(req.headers),
      meta: { keyId: id },
    });
    return NextResponse.json({ ok: true });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("api-keys DELETE", err);
    return NextResponse.json({ error: "Failed to revoke API key" }, { status: 500 });
  }
}
