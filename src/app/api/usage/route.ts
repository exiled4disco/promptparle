import { NextResponse } from "next/server";
import { AuthError, requireUser } from "@/lib/auth";
import { getUsageSummary } from "@/lib/usage";

export async function GET() {
  try {
    const user = await requireUser();
    // Portal session API may include stored prompt bodies for history compare UI.
    const summary = await getUsageSummary(user.id, {
      includePromptBodies: true,
    });
    return NextResponse.json(summary);
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("usage GET", err);
    return NextResponse.json({ error: "Failed to load usage" }, { status: 500 });
  }
}
