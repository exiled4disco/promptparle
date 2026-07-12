import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import { createApiKey, listApiKeys } from "@/lib/api-keys";
import { writeAudit } from "@/lib/audit";
import { getClientIpFromHeaders } from "@/lib/ip-allowlist";

export async function GET() {
  try {
    const user = await requireUser();
    const keys = await listApiKeys(user.id);
    return NextResponse.json({ keys });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("api-keys GET", err);
    return NextResponse.json({ error: "Failed to load API keys" }, { status: 500 });
  }
}

const postSchema = z.object({
  name: z.string().min(1).max(120),
});

export async function POST(req: NextRequest) {
  try {
    const user = await requireUser();
    const body = await req.json();
    const parsed = postSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Name is required" }, { status: 400 });
    }

    const { record, fullKey } = await createApiKey(user.id, parsed.data.name);
    await writeAudit({
      action: "apikey.create",
      userId: user.id,
      ip: getClientIpFromHeaders(req.headers),
      meta: { keyId: record.id, name: record.name, prefix: record.keyPrefix },
    });

    return NextResponse.json({
      key: {
        id: record.id,
        name: record.name,
        keyPrefix: record.keyPrefix,
        scope: record.scope,
        status: record.status,
        createdAt: record.createdAt,
      },
      // Shown once. never stored or returned again
      fullKey,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("api-keys POST", err);
    return NextResponse.json({ error: "Failed to create API key" }, { status: 500 });
  }
}
