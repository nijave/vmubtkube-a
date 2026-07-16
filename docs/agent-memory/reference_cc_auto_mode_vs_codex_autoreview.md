---
name: reference-cc-auto-mode-vs-codex-autoreview
description: "Claude Code's auto permission mode uses a real LLM classifier (Sonnet 4.6); Codex's analog is Auto-review/Guardian"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 7834b754-b41c-48f9-8d28-3237e4c71474
---

Both Claude Code and Codex have an LLM-based "auto" approval mode — not rule-based. Corrected a stale belief on 2026-07-11.

**Claude Code `auto` mode** (research preview, March 2026): a separate classifier model (Sonnet 4.6) reviews each non-allowlisted tool call before it runs. Two-stage — fast single-token filter ("err toward blocking") then CoT only on flags. Sees user messages + tool calls, NOT tool results. `deny`/`ask` rules and a safe-tool allowlist fire first; entering auto drops broad code-exec rules (`Bash(*)`, wildcarded interpreters) so the classifier sees them. Circuit breaker: 3 consecutive / 20 total denials → escalate (headless terminates). Configurable via `autoMode.{environment,allow,soft_deny,hard_deny}` (prose rules). Enable: `claude --enable-auto-mode` (Team+), cycle to it with **Shift+Tab** (not Ctrl-Tab). Docs: code.claude.com/docs/en/permission-modes + /auto-mode-config; engineering post anthropic.com/engineering/claude-code-auto-mode.

**Codex Auto-review (Guardian reviewer)** is the direct analog: `approvals_reviewer = "auto_review"` (toggleable live via `/experimental`). Key difference — Codex is sandbox-first, so the reviewer only fires at the **sandbox boundary** (out-of-workspace, network, blocked path); in-sandbox commands never reach it. Claude Code's classifier sits on every tool call (allowlist is just a short-circuit). Codex circuit breaker: 3 consecutive / 10-of-last-50.

**Why:** I asserted Claude Code's auto-approval was "rule-based, not a classifier" from pre-March-2026 memory and the user corrected it. Always verify current Claude Code features before describing them — this harness moves fast.

Related: [[reference-private-registry]] is unrelated; no direct links yet.
