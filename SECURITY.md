# Security policy

## Supported versions

Security fixes go into the `main` branch and the next release. Older releases are not patched: build the latest release or `main`.

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub: [Report a vulnerability](https://github.com/Breitec/crabbar/security/advisories/new) (Security tab → "Report a vulnerability").

Say what you found, how to reproduce it and what an attacker could do with it. CrabBar is a spare-time project, so expect a first answer within a week. Once a fix is out, the advisory is published, with credit if you want it.

Reports in German are welcome too.

## What counts

For example:

- CrabBar running a command, script or tool beyond reading without your click, e.g. because of a chat reply, text Clawd read from a file, web page or mail, or a task file Claude wrote or changed. By design, Auto runs the chat's scripts and tool calls without a click (scripts a task proposes still wait), and tools you allowed for a task also work in the chat. A task uses the tools you allowed for it without asking again, and what it reads can steer them, so allow a task only what it may do unattended (a whole MCP server includes sending and deleting). Allow rules and hooks in your own Claude Code settings apply to the chat and tasks too.
- the chat or a task picking up settings, hooks, CLAUDE.md, skills, agents, commands or auto-memory from Clawd's folder, or MCP servers set up for it (local scope or its .mcp.json), also when Clawd's Remote Control session wrote them,, a task without an `mcp__` rule starting an MCP server, or a task's prompt getting the chat's context
- data leaving the Mac for hosts other than those the README names under "How it works" and "Privacy and safety" (what `claude` itself sends to Anthropic is up to Claude Code)
- the update check downloading or running anything, or opening a page other than CrabBar's own release page
- the `crabbar://` URL scheme doing more than refreshing or opening CrabBar's own windows
- the iCloud snapshot reaching anyone but your own Apple Account

Not in scope: bugs in Claude Code itself (see [its security policy](https://github.com/anthropics/claude-code/security/policy)), what Clawd's Remote Control session itself does on your behalf (it runs with your own Claude Code permissions), and attacks that need someone who can already run code as your user on your Mac.
