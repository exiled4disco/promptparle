/**
 * "Invite a friend" narrative. PromptParle is free and open to sign up;
 * invitations are now an optional nicety for sharing, not a gate.
 */

export const INVITE_WHY = {
  title: "Invite a friend",
  lead:
    "PromptParle is free and open. Invitations are just a friendly way to bring someone along.",
  body: [
    {
      title: "Anyone can create a free account",
      text: "No code, no waitlist, no gatekeeping. Sign up with email and password (or Google / GitHub), and you're in. Each desktop still gets its own pp_live_ license key.",
    },
    {
      title: "Invitations are a nicety, not a requirement",
      text: "Want to bring a teammate or a friend? Send them an invite from your account. It's a warm hand-off, not the only door in, they can also just sign up directly.",
    },
    {
      title: "Support the project if it helps you",
      text: "PromptParle is free. If it saves you real money on tokens, an optional pay-what-you-can donation keeps the gateway boringly reliable and the roadmap moving.",
    },
  ],
  closer:
    "The doors are open: create a free account, make a desktop license key, install, and see your savings. Invite a friend when you're ready, no code required.",
} as const;
