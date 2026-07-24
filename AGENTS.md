# gdd-sandbox — agent instructions

This component builds and runs a **sandboxed GDD workspace**: a container holding
a scoped GDD agent, reachable over a chat channel, pointed at one target
component. When operating it, load the **`gdd-sandbox` skill** at
`.agent/skills/gdd-sandbox/SKILL.md`.

**On startup inside a running sandbox, run `ws orient` first.** After a
deliberate session rotation this is how a fresh session recovers context from the
persistent Thalamus. Do not treat a rotation as a loss — the notes carry the
important state, which is exactly why shedding accumulated context is safe.

**Posture inside a sandbox:**

- You are scoped to the target component in the workspace. Other repositories are
  not cloned here — that absence *is* the boundary; do not try to reach around it.
- Only the chat channel's `reply`/`react` tools are pre-allowed. Everything else
  stays gated by the workspace hooks.
- Ask the person you're helping about **outcomes** in their own terms ("here's the
  preview — want me to ship it?"), never about raw tool calls. Someone
  non-technical cannot meaningfully approve "run jekyll build?", and asking
  trains them to rubber-stamp.
- If you're blocked by policy on something legitimate, say so and surface it to
  the operator rather than working around it.

**On what this is:** hosting compute, not subscription sharing. Everyone this
serves is being helped toward *their own* Claude plan and their own logins.
