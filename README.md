# gdd-sandbox

> **Status: WIP / pre-implementation.** This component is being designed.
> The design doc lives in `docs/plans/`. Nothing here is wired up yet.

A GDD **sandboxed workspace** builder: it builds and runs a Docker container
holding a scoped GDD agent, reachable over a chat channel (Discord today,
other transports later). The container is pointed at a target component to
work on and is provisioned so a non-technical person can collaborate with the
agent over chat.

This capability is **agnostic** — it is not tied to any one site or user.
The first pilot use is helping a non-technical friend maintain a GitHub-Pages
campaign site, but no user- or site-specific content lives here (that belongs
in the user's own realm repo and their site component).

**Not** a way to share a Claude subscription. Each person the sandbox serves is
being helped toward their *own* Claude plan and logins; the sandbox is about
hosting compute and shaping the workflow, never sharing entitlement.
