# Security

Earshot can answer Claude Code permission prompts and hold or block tool calls, so bugs in it can matter. Thanks for looking.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting instead: go to the **Security** tab of the repository and click **Report a vulnerability**, or open [this link](https://github.com/knQzx/earshot/security/advisories/new).

Include what you found, how to reproduce it and which version or commit you tested. You will get an answer as soon as I can manage; this is a one-person project, so please allow some time. Once a fix is released the advisory is published with credit to you, unless you prefer otherwise.

## Supported versions

Only the latest release gets fixes.

## Threat model

### Trust boundary

Earshot assumes that every process running as your macOS user is trusted, and every other user is not. This matches how Claude Code itself works: anything running as you can already edit `~/.claude/settings.json` or type into your terminal.

### What Earshot guarantees

- **Only your user can talk to the app.** The socket `~/Library/Application Support/Earshot/earshot.sock` is created with mode 0600 inside a 0700 directory, and the app checks every connecting peer's uid with `getpeereid`. Connections from other users are dropped.
- **The hook only trusts the real app.** Before it uses a reply, `earshot-hook` checks that the process on the other end of the socket is the Earshot app from the same bundle as the hook. Another program listening on the socket path cannot answer for it.
- **Nothing is approved without a click.** The hook prints an `allow` decision only after the app replied `allow` or `always` to a click on Allow or Always (or ⌘↩ while the panel has focus). There are no rules that approve anything by themselves, and no timeout that turns into an allow.
- **The policy only makes things stricter.** Rules are Off, Ask or Block. Ask holds a tool call until you answer; approving it lets the call continue only when every part of the command is covered by the rule, otherwise Claude Code's own permission flow decides. Block refuses the call.
- **Clicks need intent.** Freshly shown buttons ignore clicks and keyboard shortcuts for 400 ms, so a pill appearing under the pointer cannot be approved by a click that was meant for something else.
- **Failures fall back to Claude Code.** If the app is not running, crashes or misbehaves, the hook exits 0 and leaves the decision to Claude Code: a permission request goes to the terminal dialog, which Claude Code shows in parallel anyway, and a policy Ask falls back to `ask`, so Claude Code prompts in the terminal. It never falls back to `allow`.
- **Block rules work without the app.** The hook reads `policy.json` itself and answers Block rules on its own.
- **The policy file fails safe.** `policy.json` is written atomically with mode 0600. If it goes missing or cannot be parsed, the hook uses the last copy that worked, or the built-in defaults. A broken file never turns the policy off.
- **Claude cannot quietly edit the guard.** A built-in rule, on by default, asks before Claude edits Earshot's own files or Claude Code's settings.
- **Your deny rules win.** Claude Code only asks the permission hook when it would otherwise show a dialog, and according to its documentation it evaluates your deny and ask rules whatever a `PreToolUse` hook returns. Earshot cannot approve something your Claude Code settings deny.
- **Stop only reaches Claude's helpers.** The Stop button in a memory alert sends `SIGTERM` after a confirmation click, and only to a process that descends from one of your Claude sessions. It refuses pid 1, Earshot itself, the sessions' own `claude` processes and anything else.
- **No network.** The code contains no networking APIs and CI fails if any are added (`make check-no-network`). Hook payloads, which include your prompts and commands, never leave the machine.
- **Limited file access.** Earshot changes `~/.claude/settings.json` only when you install or remove the hooks, only touches its own hook entries, and keeps a backup of the original file the first time. In `~/.claude` it otherwise only reads `sessions/<pid>.json` and the tail of that session's transcript, to show titles; it never opens `*.key` files or other credentials.
- **The plugin adds nothing new.** The plugin's hook is a short shell script that runs `earshot-hook` from `Earshot.app` in `~/Applications` or `/Applications`, and does nothing if the app is not there or the same hooks are already in `settings.json`.

### The policy is a speed bump, not a sandbox

Rules match the text of tool calls. Earshot handles the common ways a command gets wrapped:

- chains and pipes: `&&`, `||`, `;`, `|`, `&`, newlines
- subshells, `{ ...; }` groups, `$(...)` and backticks
- `sh -c`, `bash -c`, `zsh -c` and `eval` with the script inline
- prefixes: variable assignments, `env`, `sudo`, `command`, `builtin`, `time`, `nohup`, `exec`, `nice`, `xargs`
- a full path to the program, like `/usr/bin/git`
- for file tools, paths resolved against the session's folder, `~` and `$HOME`

An agent can still phrase a command so that no pattern sees it: write a script and run it, use another language (`python -c`, `node -e`), an alias or a shell function, a variable that holds the command, an encoded string, or a tool or MCP server that does the same thing. Treat Ask and Block as a way to keep yourself in the loop for the usual risky commands, and use real isolation (a separate user, a container, a VM) when you need a boundary.

### Out of scope

- Malware or other code running as your user. It can edit your settings or `policy.json` directly, drive your terminal, or talk to the socket (including reading the session list that `earshot-hook --list` shows); Earshot cannot defend against it.
- Getting around the policy by rewording a command, as described above. A common, plainly risky command that a catalog rule misses is still worth a normal issue.
- Changes in Claude Code's undocumented session files. If they break, titles fall back to simpler labels.
- A tampered app bundle. Builds are ad-hoc signed, which says nothing about who built them. Build from source, or compare the SHA-256 published with each release.
- Bugs in Claude Code's own permission system.

Things that are in scope and worth reporting include: a way for another user to reach the socket, a way to answer the hook from something other than the Earshot app, any path where the hook prints `allow` without a click, a policy error that turns rules off, a bug that makes a rule stop applying to a command it plainly matches, a way to make a pill approve something different from what it shows, Stop reaching a process outside your Claude sessions, crashes in the hook that break Claude Code sessions, and anything that sends data off the machine.
