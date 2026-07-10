import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import {
  isProviderEnabled,
  isValidProvider,
  listProviderCredentials,
  upsertProviderCredential,
} from "@/lib/providers";
import { PROVIDERS } from "@/lib/constants";

export async function GET() {
  try {
    const user = await requireUser();
    const credentials = await listProviderCredentials(user.id);
    return NextResponse.json({
      providers: PROVIDERS,
      credentials,
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("providers GET", err);
    return NextResponse.json({ error: "Failed to load providers" }, { status: 500 });
  }
}

const postSchema = z.object({
  provider: z.string(),
  apiKey: z.string().min(8).max(512),
  label: z.string().max(120).optional(),
});

export async function POST(req: NextRequest) {
  try {
    const user = await requireUser();
    const body = await req.json();
    const parsed = postSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid input" }, { status: 400 });
    }

    const { provider, apiKey, label } = parsed.data;
    if (!isValidProvider(provider)) {
      return NextResponse.json({ error: "Unknown provider" }, { status: 400 });
    }
    if (!isProviderEnabled(provider)) {
      return NextResponse.json(
        { error: "This provider is not enabled yet" },
        { status: 400 }
      );
    }

    const credential = await upsertProviderCredential(
      user.id,
      provider,
      apiKey,
      label
    );

    return NextResponse.json({ credential });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("providers POST", err);
    return NextResponse.json({ error: "Failed to save provider key" }, { status: 500 });
  }
}
