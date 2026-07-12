import { NextRequest, NextResponse } from "next/server";
import { AuthError, requireAdmin } from "@/lib/auth";
import { listFeedback } from "@/lib/feedback";

export async function GET(req: NextRequest) {
  try {
    await requireAdmin();
    const status = req.nextUrl.searchParams.get("status");
    const rows = await listFeedback({ status });
    return NextResponse.json({
      feedback: rows.map((r) => ({
        id: r.id,
        kind: r.kind,
        title: r.title,
        body: r.body,
        source: r.source,
        email: r.email,
        name: r.name,
        ip: r.ip,
        country: r.country,
        status: r.status,
        adminNote: r.adminNote,
        createdAt: r.createdAt,
        user: r.user,
      })),
      summary: {
        total: rows.length,
        new: rows.filter((r) => r.status === "new").length,
        bugs: rows.filter((r) => r.kind === "bug").length,
        suggest: rows.filter((r) => r.kind === "suggest").length,
      },
    });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("admin feedback GET", err);
    return NextResponse.json(
      { error: "Failed to load feedback" },
      { status: 500 }
    );
  }
}
