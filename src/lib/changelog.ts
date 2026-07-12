import { promises as fs } from "fs";
import path from "path";

/**
 * Read the repo-root CHANGELOG.md at request time (server only).
 * Returns null if the file is not present yet (graceful fallback).
 * CHANGELOG.md is repo-owned/trusted content.
 */
export async function readChangelog(): Promise<string | null> {
  try {
    const file = path.join(process.cwd(), "CHANGELOG.md");
    const text = await fs.readFile(file, "utf8");
    return text.trim() ? text : null;
  } catch {
    return null;
  }
}
