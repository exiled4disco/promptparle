import { NextResponse } from "next/server";
import { cookies } from "next/headers";
import { clearSessionCookie, destroySession } from "@/lib/auth";
import { SESSION_COOKIE } from "@/lib/constants";

export async function POST() {
  const cookieStore = await cookies();
  const token = cookieStore.get(SESSION_COOKIE)?.value;
  if (token) {
    await destroySession(token);
  }
  await clearSessionCookie();
  return NextResponse.json({ ok: true });
}
