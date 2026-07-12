export type FaqItem = {
  q: string;
  a: string;
  category: string;
};

/**
 * Public FAQ; product-facing only.
 * Avoid proprietary internals, exact algorithms, infra topology, and third-party IP.
 */
export const FAQ_ITEMS: FaqItem[] = [
  // --- Product ---
  {
    category: "Product",
    q: "What is PromptParle?",
    a: "PromptParle is an AI context optimization gateway. It sits between your desktop tools and providers like OpenAI, Claude, Gemini, and Grok. It thins noisy context, keeps the useful signal, helps mask secrets, and routes cleaner prompts so you pay for less filler.",
  },
  {
    category: "Product",
    q: "What problem does it solve?",
    a: "Large logs, docs, and code dumps burn tokens and bury the ask. Users hit plan limits mid-work. AI vendors bill on volume, they are not built to shrink your spend. PromptParle sends leaner, higher-signal context while you keep the models and accounts you already pay for.",
  },
  {
    category: "Product",
    q: "How does PromptParle save money?",
    a: "You choose OpenAI, Claude, Gemini, or Grok models your key allows. PromptParle reduces bloated context so flagship models cost less per useful turn. Completions stay live from your provider every request.",
  },
  {
    category: "Product",
    q: "I already use agents and local workflows. Why still use this?",
    a: "Agents and multi-step local workflows can spread work, but every hop can still ship a fat context window. PromptParle optimizes the shared problem underneath: tokens that should never have hit the meter.",
  },
  {
    category: "Product",
    q: "Can this help when I hit provider plan limits?",
    a: "Often yes. Many free and mid-tier plans cut you off with “you’ve reached your max.” Stripping bloated tokens means fewer tokens per request, which can delay that wall or stop it for some workloads. Results depend on how noisy your context was.",
  },
  {
    category: "Product",
    q: "Why don’t AI companies just optimize my token spend?",
    a: "Tokens are their revenue model. Larger context windows and heavy usage grow that business. PromptParle exists for the buyer side: keep the model quality you need, pay for less noise.",
  },
  {
    category: "Product",
    q: "Is PromptParle a chat app or a model?",
    a: "Neither. It is not its own foundation model. Chat runs in the free desktop client on your machine. Models are provided by the AI vendors you configure with your own API keys.",
  },
  {
    category: "Product",
    q: "What is the difference between the portal and the desktop client?",
    a: "The portal handles invitations, plan, and desktop license keys (pp_live_…), plus optional usage stats. Day-to-day chat, optimize, provider keys, workspace, Git, and SSH run in the local desktop client (pp) on your PC.",
  },
  {
    category: "Product",
    q: "What is the compression dial?",
    a: "A 1-5 control that trades fidelity for token savings: 1 Max Fidelity, 2 High Fidelity, 3 Optimized, 4 High Savings, 5 Max Savings. Lower numbers keep more of the original text; higher numbers aim for more reduction on noisy material. Typical bands: ~0-10% at dial 1 up to ~50-80% at dial 5 on noisy packs. Unique prose may show little or no reduction.",
  },
  {
    category: "Product",
    q: "What are optimization profiles?",
    a: "Job-oriented presets such as general, developer, security-review, log-analysis, documentation, and executive-summary. They bias what kinds of content to prefer keeping. They are not a guarantee of a fixed savings percentage.",
  },
  {
    category: "Product",
    q: "Which AI providers are supported?",
    a: "OpenAI, Anthropic (Claude), Google Gemini, and xAI Grok when you supply a valid provider API key. Availability of specific models depends on your provider account and key permissions.",
  },
  {
    category: "Product",
    q: "Do you train models on my prompts?",
    a: "PromptParle is not a foundation-model trainer. Whether a third-party provider trains on API traffic is governed by that provider’s terms and your agreement with them. Use their enterprise/API settings if you need stricter data handling.",
  },

  // --- Access ---
  {
    category: "Access & accounts",
    q: "Why is PromptParle invitation-only?",
    a: "Soft opening, not secrecy. We pace seats so onboarding, install, and support stay intentional while we scale capacity and polish the app flow. Request an invitation, we send a one-time code when we can take great care of you. Details: https://promptparle.com/trust#invite",
  },
  {
    category: "Access & accounts",
    q: "Is invitation-only permanent?",
    a: "No. Invitation-only is temporary while we scale. As install, dial savings, and desktop reliability feel solid, we open more seats and move toward broader access. The product is real; we are seating tables as fast as we can serve them well.",
  },
  {
    category: "Access & accounts",
    q: "How do I get an invitation?",
    a: "Use Request invitation on the site. We review requests and, if approved, email a one-time invitation code (and optionally a link). That code is required to create an account and to finish desktop install.",
  },
  {
    category: "Access & accounts",
    q: "I have a code. What next?",
    a: "Open Create account, enter the code, set your password for the invited email, sign in, create a desktop license key (pp_live_…), run the installer and paste that key, then set OpenAI/Claude/Gemini/Grok keys in the local UI (⋯ → Providers) or with Set-PromptParleProviderKey.",
  },
  {
    category: "Access & accounts",
    q: "Can I sign in with Google or GitHub?",
    a: "When those options are enabled for the deployment, yes; for accounts that already completed invitation onboarding. Invitation is still required to create access.",
  },
  {
    category: "Access & accounts",
    q: "I forgot my password. What do I do?",
    a: "Use Forgot password on the sign-in page. If email delivery is configured, you will get a time-limited reset link. OAuth-only accounts may not have a password until you set one in Settings.",
  },
  {
    category: "Access & accounts",
    q: "Can I share one account across a whole team?",
    a: "Plans can allow concurrent desktop seats, but sharing a single login is not a substitute for proper user accounts. Prefer one person per account for auditability and key hygiene.",
  },

  // --- Keys & billing ---
  {
    category: "Keys & billing",
    q: "What is BYOK?",
    a: "Bring Your Own Key. You store OpenAI, Claude, Gemini, or Grok API keys on your PC (desktop 0.25+). The desktop calls that provider directly; the provider bills your account for model usage. PromptParle does not hold those keys for day-to-day chat.",
  },
  {
    category: "Keys & billing",
    q: "Where are provider keys stored?",
    a: "On your machine only for desktop chat: local UI ⋯ → Providers, or Set-PromptParleProviderKey (DPAPI on Windows when available). They are not uploaded to PromptParle.",
  },
  {
    category: "Keys & billing",
    q: "How do I enter or edit a model API key?",
    a: "Run pp, open the local browser UI, then ⋯ menu → Providers. Choose the provider, paste the key, click Save on this PC. To change a key, paste the new one and save again. PowerShell: Set-PromptParleProviderKey -Provider openai -ApiKey '…'.",
  },
  {
    category: "Keys & billing",
    q: "What is a desktop API Key?",
    a: "A license key (starts with pp_live_) that proves this PC may use your PromptParle account. Create it under portal API Keys. The full value is shown once; the portal stores a hash. It is not an OpenAI/Claude key, set those on the PC separately.",
  },
  {
    category: "Keys & billing",
    q: "Who pays for AI tokens?",
    a: "You do, via your provider account (BYOK on the PC). PromptParle’s value is reducing how much noisy context you send. Product plans are separate from provider token invoices.",
  },
  {
    category: "Keys & billing",
    q: "Does PromptParle mark up provider prices?",
    a: "No. Provider usage is billed by the provider to your key. Any PromptParle plan fees are for the product itself, not a hidden surcharge on every token from the model vendor.",
  },
  {
    category: "Keys & billing",
    q: "Can I revoke a desktop key?",
    a: "Yes. Revoke it in the portal under API Keys. The desktop client will stop authenticating with that key; create a new one if needed.",
  },
  {
    category: "Keys & billing",
    q: "What is the API IP allowlist?",
    a: "An optional list of IPs allowed to use your desktop API keys. Empty means unrestricted. Browser portal sessions are not gated by that list the same way desktop keys are.",
  },

  // --- Desktop ---
  {
    category: "Desktop client",
    q: "What platforms are supported?",
    a: "Windows (PowerShell 5.1 or PowerShell 7+) and Linux/macOS with PowerShell 7 (pwsh) and git. The local UI runs in your browser against a server bound to 127.0.0.1 on your machine.",
  },
  {
    category: "Desktop client",
    q: "How do I install on Windows?",
    a: "Open the Install page and run the Windows command (irm …/install.ps1 | iex). That bootstrap clones the project from GitHub, validates your invitation code, installs the module, and asks for your pp_live_ key.",
  },
  {
    category: "Desktop client",
    q: "How do I install on Linux or macOS?",
    a: "Install git and PowerShell 7, then open the Install page and run the Linux/macOS command (curl …/install.sh | bash). Same GitHub-based flow as Windows after the bootstrap download from this site.",
  },
  {
    category: "Desktop client",
    q: "How do I start local chat?",
    a: "After install, open PowerShell and run pp. That starts the local server and opens the browser UI at http://127.0.0.1. Leave the PowerShell window open while you chat. For terminal-only chat: Start-PromptParle -Cli. Stop with the UI control or Stop-PromptParleLocalServer.",
  },
  {
    category: "Desktop client",
    q: "Where does the desktop store its config?",
    a: "Under your user profile (for example ~/.promptparle/config.json on Unix, or %USERPROFILE%\\.promptparle on Windows). That file holds the desktop license key, local provider keys (protected), and preferences. On Windows, DPAPI is used when available.",
  },
  {
    category: "Desktop client",
    q: "Do SSH, Git, and workspace credentials leave my PC?",
    a: "No. Remote access and repo credentials stay on your machine. They are not uploaded to PromptParle as part of normal SSH/Git/workspace use.",
  },
  {
    category: "Desktop client",
    q: "What about secret masking?",
    a: "On desktop 0.25+, a secret gate runs on your PC before any model call (mask credential-shaped patterns; strict policy can block residual high-confidence secrets). No scanner is perfect, still avoid pasting production secrets when you can.",
  },
  {
    category: "Desktop client",
    q: "Does “local-first” mean my prompts never leave my PC?",
    a: "Prompt and context stay on your PC for optimize. Model calls go from your PC directly to OpenAI/Claude/Gemini/Grok with your local provider key. The PromptParle portal is for license and account, not on the model path. Details: https://promptparle.com/trust",
  },
  {
    category: "Desktop client",
    q: "How do updates work?",
    a: "The local UI can check for client updates and apply a portal-published package. You can also re-run the installer or use the module’s update command. After updating, hard-refresh the browser tab.",
  },
  {
    category: "Desktop client",
    q: "Can I use it offline?",
    a: "Yes for local work: the UI, dial optimize, and tools that only touch your machine run on your PC without sending prompts to PromptParle. Model calls need network access to your AI provider. Occasional license checks may contact PromptParle.",
  },

  // --- Privacy & security ---
  {
    category: "Privacy & security",
    q: "What data does the portal store?",
    a: "Account profile, hashed desktop keys, usage stats, and session titles. Prompt and context text are not stored in the cloud (stats-only product policy). Provider keys for desktop chat live on your PC, not in the portal.",
  },
  {
    category: "Privacy & security",
    q: "Do you store my prompts or context?",
    a: "No. Usage history is token stats and session titles only. Prompt and context bodies are not captured or retained in the portal.",
  },
  {
    category: "Privacy & security",
    q: "Is traffic encrypted in transit?",
    a: "The public site is served over HTTPS. Your connection to AI providers also uses those providers’ HTTPS APIs.",
  },
  {
    category: "Privacy & security",
    q: "Who can see my invitation requests?",
    a: "Operators who manage invitations for the deployment. Do not put secrets in the optional note field on the request form.",
  },
  {
    category: "Privacy & security",
    q: "Is the product open source?",
    a: "Client and portal source may be published under the project’s repository and license terms. That does not mean every internal system, process, or partner integration is public. Check the repository LICENSE and SECURITY docs for the authoritative statement.",
  },

  // --- Usage & results ---
  {
    category: "Usage & results",
    q: "When are savings high vs near-zero?",
    a: "Often high: noisy logs, duplicated frames, fat security packs, multi-file dumps, agent chains that re-ship the same context. Often near-zero: short unique questions and already-tight prose, there is little honest bloat to remove. That is correct behavior, not a failure. See https://promptparle.com/examples",
  },
  {
    category: "Usage & results",
    q: "Why do I sometimes see 0% reduction?",
    a: "Short prompts and already-compact unique text often cannot shrink further without losing meaning. Clean prose is already signal. Savings show up more on noisy logs, duplicates, and filler-heavy packs.",
  },
  {
    category: "Usage & results",
    q: "Are savings guarantees?",
    a: "No. “Keep the signal” is the goal, not a fixed percent. We are still measuring real workloads; published example packs (Noisy ~78%, Security ~60%, Clean ~2%) show the shape of results so far. Proof today is the dial savings line in the desktop UI per turn.",
  },
  {
    category: "Usage & results",
    q: "What do you actually optimize (heuristics)?",
    a: "Open categories include: repetition/near-duplicates, boilerplate, structure-over-bulk, profile bias (security/log/dev/etc.), dial 1-5 fidelity tradeoff, and secret masking. We do not publish the full scoring IP. See https://promptparle.com/trust",
  },
  {
    category: "Usage & results",
    q: "Where do I see savings?",
    a: "In the desktop client’s savings views (per turn) and optionally in the portal Usage page (token stats and session titles). Full prompt text is not stored in the cloud.",
  },
  {
    category: "Usage & results",
    q: "Does Optimize-only still call the model?",
    a: "Optimize-only paths are meant to compress and report savings without a full provider completion. Full chat/completions still call your configured model.",
  },

  // --- Pricing & trust ---
  {
    category: "Keys & billing",
    q: "How much does PromptParle cost?",
    a: "Flat product pricing: Free $0, Pro $29.99/month, Team of 5 $99.99/month. Yearly billing is 20% off. AI provider tokens are always separate (BYOK). Not priced by the request. https://promptparle.com/pricing",
  },
  {
    category: "Keys & billing",
    q: "Is pricing based on daily requests?",
    a: "No. Subscriptions are fixed monthly or yearly. Soft fair-use protection may exist so free accounts do not overwhelm the fleet, that is not the Pro/Team price model.",
  },
  {
    category: "Privacy & security",
    q: "Does my prompt go through PromptParle servers?",
    a: "No on desktop client 0.25+. Optimize and the model call run on your PC; the provider is called directly with a local key. The portal handles account, plan, and the pp_live_ desktop key. https://promptparle.com/trust",
  },
  {
    category: "Privacy & security",
    q: "Where are my AI provider keys stored?",
    a: "On your PC only (DPAPI on Windows when available). Set-PromptParleProviderKey or Providers in the local UI. They are never uploaded to PromptParle. The separate pp_live_ desktop key is only for license/entitlements.",
  },
  {
    category: "Privacy & security",
    q: "What does the portal see?",
    a: "Account, plan, hashed desktop keys, invitations. Not your prompt/context bodies and not your OpenAI/Claude/Gemini/Grok keys (local-first 0.25+).",
  },
  {
    category: "Privacy & security",
    q: "Who should not use PromptParle?",
    a: "Anyone who cannot send optimized context to their chosen AI provider (that path still exists, it is the model). If you need fully air-gapped inference with no external model at all, this product is not that. For hop/key-custody concerns vs PromptParle itself: local-first removes PromptParle from that path.",
  },

  // --- Support ---
  {
    category: "Support",
    q: "Install fails on invitation code. Why?",
    a: "Common causes: code not yet accepted on the portal, typo, already redeemed, or expired. Finish the email/portal form first, then re-run the installer with the same code.",
  },
  {
    category: "Support",
    q: "Desktop says unauthorized. Why?",
    a: "Usually a revoked, incomplete, or wrong pp_live_ key, or an IP allowlist that does not include your current address. Create a new key and check Settings → API IP allowlist.",
  },
  {
    category: "Support",
    q: "Local UI will not open.",
    a: "Confirm the PowerShell window is still running, the port is free, and you are browsing http://127.0.0.1 (not a remote host). Try Stop-PromptParleLocalServer then pp again.",
  },
  {
    category: "Support",
    q: "How do I uninstall?",
    a: "Use Uninstall-PromptParle from the module or the uninstall script in the repo. Optional flags can remove local config and the git clone.",
  },
  {
    category: "Support",
    q: "How do I get help?",
    a: "Start with the desktop Help panel and the GitHub README. For account or invitation issues, reply to onboarding email or contact the operator who invited you.",
  },
  {
    category: "Support",
    q: "Can I use PromptParle for regulated or classified work?",
    a: "Only under your organization’s policies. You must validate provider terms, data residency, logging settings, and network controls yourself. PromptParle does not replace your compliance program.",
  },
];

export const FAQ_CATEGORIES = [
  "Product",
  "Access & accounts",
  "Keys & billing",
  "Desktop client",
  "Privacy & security",
  "Usage & results",
  "Support",
] as const;
