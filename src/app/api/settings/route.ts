import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { AuthError, requireUser } from "@/lib/auth";
import { prisma } from "@/lib/db";

const schema = z.object({
  name: z.string().max(120).optional(),
  retentionPolicy: z.enum(["none", "7d", "30d"]).optional(),
  storePrompts: z.boolean().optional(),
});

export async function PATCH(req: NextRequest) {
  try {
    const user = await requireUser();
    const body = await req.json();
    const parsed = schema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json({ error: "Invalid input" }, { status: 400 });
    }

    const updated = await prisma.user.update({
      where: { id: user.id },
      data: {
        ...(parsed.data.name !== undefined
          ? { name: parsed.data.name.trim() || null }
          : {}),
        ...(parsed.data.retentionPolicy !== undefined
          ? { retentionPolicy: parsed.data.retentionPolicy }
          : {}),
        ...(parsed.data.storePrompts !== undefined
          ? { storePrompts: parsed.data.storePrompts }
          : {}),
      },
      select: {
        id: true,
        email: true,
        name: true,
        plan: true,
        retentionPolicy: true,
        storePrompts: true,
      },
    });

    return NextResponse.json({ user: updated });
  } catch (err) {
    if (err instanceof AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("settings PATCH", err);
    return NextResponse.json({ error: "Failed to update settings" }, { status: 500 });
  }
}
