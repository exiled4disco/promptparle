import { NextResponse } from "next/server";

/**
 * Portal browser chat is disabled on purpose.
 * AI calls from the portal would bill provider usage through our hosted path.
 * Chat runs only on the desktop client (pp) via /api/v1/prompt with the user's key.
 */
const GONE = {
  error:
    "Portal chat is disabled. Use the desktop client (pp) so AI traffic stays on your machine and provider keys.",
  code: "portal_chat_disabled",
};

export async function GET() {
  return NextResponse.json(GONE, { status: 410 });
}

export async function POST() {
  return NextResponse.json(GONE, { status: 410 });
}

export async function PUT() {
  return NextResponse.json(GONE, { status: 410 });
}

export async function PATCH() {
  return NextResponse.json(GONE, { status: 410 });
}

export async function DELETE() {
  return NextResponse.json(GONE, { status: 410 });
}
