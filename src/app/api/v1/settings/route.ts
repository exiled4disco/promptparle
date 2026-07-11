import { NextRequest, NextResponse } from "next/server";
import { z } from "zod";
import { requireApiKey, V1AuthError } from "@/lib/v1-auth";
import { prisma } from "@/lib/db";
import { isValidProvider } from "@/lib/providers";
import {
  parsePreferredModelsJson,
  serializePreferredModels,
} from "@/lib/models";
import {
  getUserDesktopFeatures,
} from "@/lib/desktop-clients";
import { getPlanLimits } from "@/lib/plans";

/**
 * Desktop ↔ portal settings sync.
 * GET  — pull preferred provider/model, dial, tools, features
 * PATCH — push client settings up to portal (and vice versa from portal UI)
 */

const patchSchema = z.object({
  preferred_provider: z.string().max(40).nullable().optional(),
  preferred_models: z.record(z.string(), z.string().max(120)).optional(),
  /** Set one provider's preferred model without replacing the whole map */
  preferred_model: z
    .object({
      provider: z.string().max(40),
      model: z.string().max(120),
    })
    .optional(),
  default_dial: z.number().int().min(1).max(5).optional(),
  default_tools_enabled: z.boolean().optional(),
  store_prompts: z.boolean().optional(),
  retention_policy: z.enum(["none", "7d", "30d"]).optional(),
  feat_project_pc: z.boolean().optional(),
  feat_project_ssh: z.boolean().optional(),
  feat_project_git: z.boolean().optional(),
});

export async function GET(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const features = await getUserDesktopFeatures(auth.user.id);
    const limits = getPlanLimits(auth.user.plan);
    const preferredModels = parsePreferredModelsJson(auth.user.preferredModels);

    return NextResponse.json({
      preferred_provider: auth.user.preferredProvider || null,
      preferred_models: preferredModels,
      default_dial: auth.user.defaultDial ?? 3,
      default_tools_enabled: auth.user.defaultToolsEnabled !== false,
      store_prompts: auth.user.storePrompts,
      retention_policy: auth.user.retentionPolicy,
      project_pc: features.projectPc,
      project_ssh: features.projectSsh,
      project_git: features.projectGit,
      plan: limits.id,
      plan_label: limits.label,
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/settings GET", err);
    return NextResponse.json({ error: "Failed to load settings" }, { status: 500 });
  }
}

export async function PATCH(req: NextRequest) {
  try {
    const auth = await requireApiKey(req);
    const body = await req.json();
    const parsed = patchSchema.safeParse(body);
    if (!parsed.success) {
      return NextResponse.json(
        { error: "Invalid settings payload", details: parsed.error.flatten() },
        { status: 400 }
      );
    }
    const d = parsed.data;

    let preferredModels = parsePreferredModelsJson(auth.user.preferredModels);
    if (d.preferred_models) {
      preferredModels = { ...preferredModels, ...d.preferred_models };
    }
    if (d.preferred_model) {
      const p = d.preferred_model.provider.toLowerCase();
      if (isValidProvider(p)) {
        preferredModels[p] = d.preferred_model.model.trim();
      }
    }

    let preferredProvider = auth.user.preferredProvider;
    if (d.preferred_provider !== undefined) {
      if (d.preferred_provider === null || d.preferred_provider === "") {
        preferredProvider = null;
      } else if (isValidProvider(d.preferred_provider.toLowerCase())) {
        preferredProvider = d.preferred_provider.toLowerCase();
      } else {
        return NextResponse.json({ error: "Unknown preferred_provider" }, { status: 400 });
      }
    }

    const dial =
      d.default_dial !== undefined
        ? Math.min(5, Math.max(1, d.default_dial))
        : undefined;

    const updated = await prisma.user.update({
      where: { id: auth.user.id },
      data: {
        preferredProvider,
        preferredModels: serializePreferredModels(preferredModels),
        ...(dial !== undefined ? { defaultDial: dial } : {}),
        ...(d.default_tools_enabled !== undefined
          ? { defaultToolsEnabled: d.default_tools_enabled }
          : {}),
        ...(d.store_prompts !== undefined
          ? { storePrompts: d.store_prompts }
          : {}),
        ...(d.retention_policy !== undefined
          ? { retentionPolicy: d.retention_policy }
          : {}),
        ...(d.feat_project_pc !== undefined
          ? { featProjectPc: d.feat_project_pc }
          : {}),
        ...(d.feat_project_ssh !== undefined
          ? { featProjectSsh: d.feat_project_ssh }
          : {}),
        ...(d.feat_project_git !== undefined
          ? { featProjectGit: d.feat_project_git }
          : {}),
      },
      select: {
        preferredProvider: true,
        preferredModels: true,
        defaultDial: true,
        defaultToolsEnabled: true,
        storePrompts: true,
        retentionPolicy: true,
        featProjectPc: true,
        featProjectSsh: true,
        featProjectGit: true,
      },
    });

    return NextResponse.json({
      ok: true,
      preferred_provider: updated.preferredProvider,
      preferred_models: parsePreferredModelsJson(updated.preferredModels),
      default_dial: updated.defaultDial,
      default_tools_enabled: updated.defaultToolsEnabled,
      store_prompts: updated.storePrompts,
      retention_policy: updated.retentionPolicy,
      project_pc: updated.featProjectPc,
      project_ssh: updated.featProjectSsh,
      project_git: updated.featProjectGit,
    });
  } catch (err) {
    if (err instanceof V1AuthError) {
      return NextResponse.json({ error: err.message }, { status: err.status });
    }
    console.error("v1/settings PATCH", err);
    return NextResponse.json({ error: "Failed to save settings" }, { status: 500 });
  }
}
