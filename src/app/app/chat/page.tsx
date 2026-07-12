import { redirect } from "next/navigation";

export const metadata = { title: "Chat" };

/** Portal web chat retired. Chat lives in the desktop client (pp). */
export default function ChatPage() {
  redirect("/app");
}
