# Architecture

Earshot is a background macOS app (`LSUIElement`, no Dock icon or menu bar) plus a small command line helper, `earshot-hook`, that Claude Code runs as a hook. The two talk over a local unix socket. This document describes how the pieces fit, the wire protocol, the policy hook, the session status machine and the threat model.

Earshot is an unofficial project, not affiliated with or endorsed by Anthropic.

## Design rules

- macOS 14 or newer, Apple Silicon and Intel
- Swift 6 toolchain in Swift 5 language mode, Swift Package Manager only, no Xcode project
- Zero third-party dependencies
- No network code: no `URLSession`, no `Network.framework`, no sockets other than the local unix socket (`make check-no-network` enforces this in CI)
- Free to build and run: ad-hoc signing, no Apple developer account
- Never break Claude Code: the hook exits 0 on any failure and falls back to Claude Code's own prompt
- Only ever stricter: nothing is approved without a click in the app; the policy can hold or block a tool call, never approve one
- Little code, few comments; names should explain the code

## Overview

```
claude (each terminal)
  └─ hook ──► earshot-hook (Swift CLI) ──unix socket──► Earshot.app
       │        ▲ reply line for PermissionRequest        ├─ AppModel         owns SessionStore and GroupStore, wires everything
       │          and policy asks                         ├─ NotchController  black notch island, alert stack, glass panel (SwiftUI)
       └─ reads policy.json (PreToolUse)                  ├─ TerminalJumper   AppleScript by tty, tmux, generic
                                                          ├─ PolicySettings   Settings > Policy, writes policy.json
 ProcessScanner (libproc every 3 s) ─────────────────────►├─ ClaudeMetaReader titles from ~/.claude/sessions and transcripts
 MemoryWatch (every 10 s) ───────────────────────────────►├─ memory alerts
 UsageSampler (every 2 s, only while the module is open) ►├─ Memory and CPU module
                                                          └─ HooksInstaller   edits ~/.claude/settings.json
 earshot-hook --list ──── query ─────────────────────────► SessionSnapshot array back
 earshot-hook --simulate ─ debug ────────────────────────► fake notifications
```

The package has three targets:

| Target | Kind | What it holds |
|---|---|---|
| `EarshotCore` | library | models, wire protocol, socket server and client, hook runner and output, policy (catalog, matching, shell command splitting, store), session reducer, status phrases, Claude Code metadata reader, groups, usage sampling and memory watch, settings.json installer, launch agent, process helpers, AppleScript and tmux helpers for jumping |
| `earshot-hook` | executable | the hook binary Claude Code runs, plus `--install`, `--uninstall`, `--status`, `--list`, `--simulate`, `--version` |
| `Earshot` | executable | the app: notch island and panel, process scanner, terminal jumper, settings, login item, snapshot mode (`--snapshot`) and, in debug builds, motion traces (`--trace-*`), both on sample sessions |

All logic that can be tested without a window lives in `EarshotCore` and is covered by `EarshotCoreTests`. `Tests/E2E/drive_claude.py` drives a real Claude Code in a pty for end-to-end checks (see [CONTRIBUTING.md](CONTRIBUTING.md)).

The repository also holds a Claude Code plugin (`plugin/` and `.claude-plugin/marketplace.json`), see [Hook installation](#hook-installation).

## How Claude Code permission hooks actually behave

These facts were checked against Claude Code v2.1.308 running in a real pty. The design depends on them, so if a future Claude Code version changes any of them, Earshot needs to change too.

1. `PermissionRequest` hooks run **in parallel** with the terminal permission dialog. The dialog appears at once. If the hook answers `allow`, the open terminal dialog closes and the tool runs.
2. If the user answers in the terminal first, the hook is **not** killed; it keeps running until its own timeout. Claude continues immediately, and `PostToolUse` for that tool arrives within the same second. So the app cancels the card on the matching `PostToolUse`, `PostToolUseFailure` or `PermissionDenied` (same `tool_name` and canonical `tool_input`), or on `Stop`, `UserPromptSubmit`, `StopFailure` or `SessionEnd`, and replies `pass` so the hook exits.
3. Pressing Esc in the terminal while the dialog is open kills the hook with SIGTERM. No `Stop` event follows. So end-of-file on the socket of a pending request means "interrupted".
4. `Notification` with `notification_type=permission_prompt` arrives about 6 seconds **after** the dialog appears. It must not cancel a pending request.
5. `PermissionRequest` stdin has these keys: `cwd`, `effort`, `hook_event_name`, `permission_mode`, `permission_suggestions`, `prompt_id`, `scratchpad_dir`, `session_id`, `tool_input`, `tool_name`, `transcript_path`, plus `mcp_server` for MCP tools. `permission_suggestions` is already in `updatedPermissions` format, for example:

   ```json
   [{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"mkdir -p x"}],"behavior":"allow","destination":"localSettings"}]
   ```

6. `PreToolUse` for `AskUserQuestion` blocks the tool until the hook returns, so the hook must **not** wait on it. Questions are display-only in the notch.
7. A Claude Code process has `comm` = `claude`, and its executable is `~/.local/share/claude/versions/<version>`, so the executable's basename is the version number, not `claude`.

### Decision output

The hook prints one of these on stdout and exits 0:

| Decision | Output |
|---|---|
| allow | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` |
| always | the same, plus `"updatedPermissions": <permission_suggestions>` inside `decision` |
| deny | `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied from Earshot"}}}` |
| pass | nothing; the terminal dialog stays in charge |

`always` is only offered when `permission_suggestions` is present and not empty.

## The policy hook

Policy rules run in the `PreToolUse` hook, which Claude Code calls before a tool runs and before its own permission check. The policy can only make things stricter: it holds a call until you answer, or blocks it. It never approves a call by itself. The Claude Code documentation states that deny and ask rules from settings are still evaluated whatever a `PreToolUse` hook returns, so nothing Earshot answers overrides your own deny rules.

`earshot-hook` handles `PreToolUse` like this (`Sources/EarshotCore/HookRunner.swift`):

1. Load `~/Library/Application Support/Earshot/policy.json` (`PolicyStore`). The hook reads the file itself, so the rules apply whether or not the app is running. If the file is missing or broken, it uses the last copy that worked, or the built-in defaults; a broken file never means "no rules".
2. Evaluate the call (`Policy.evaluate`). For `Bash`, the command is split into its parts (`ShellCommand.split`: `&&`, `||`, `;`, `|`, `&`, subshells, `$(...)` and backticks, `sh -c` and `eval` bodies) and common prefixes are peeled (variable assignments, `env`, `sudo`, `command`, `builtin`, `time`, `nohup`, `exec`, `nice`, `xargs`). A rule matches when any part matches; Block rules are checked before Ask rules. Other tools are matched on their file path, URL or input. Rules about "outside the project" compare resolved paths with the session's folder, its scratchpad and `~/.claude/plans`.
3. Answer:
   - **Block**: print `deny` with the reason `Blocked by Earshot policy: <rule>`. If the app is running, the event also goes to it with the match, and the app shows the Blocked pill
   - **Ask**: if the app is reachable and the process has a tty, send a `request` and hold Claude until a reply comes (the hook timeout is 86400 seconds). There is no terminal dialog for this call while it waits. When you click Allow, the hook prints `allow` only if every part of the command is covered by the rule being answered; otherwise it does not approve the call and Claude Code's own permission flow decides, as without Earshot. Deny prints `deny`. A `pass`, no reply, no tty or an unreachable app print `ask`, so Claude Code shows its own prompt
   - no match: forward the event to the app and print nothing

Before trusting a reply, the hook checks that the process on the other end of the socket is the Earshot app from the same bundle as the hook.

The output is `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"|"deny"|"ask","permissionDecisionReason":"..."}}`.

The catalog (`PolicyCatalog.swift`) groups the built-in rules: git, release and deploy, destructive commands, package installs, network, secrets and files. Each is Off, Ask or Block. Out of the box `git push`, force pushes and a rule that protects Earshot's own files and Claude Code's settings from edits by Claude are set to Ask; everything else is Off. User rules are stored next to the catalog choices in `policy.json`:

```json
{
  "version": 2,
  "catalog": {"git-push": "ask", "git-force-push": "ask", "sudo": "off"},
  "rules": [{"id": "...", "name": "docker compose down*", "enabled": true, "action": "block", "pattern": "docker compose down*"}]
}
```

A `pattern` is anchored, `*` matches anything, whitespace matches any whitespace, and a leading word may carry a path (`/usr/bin/git`). `regex:` takes a raw regular expression. Matching is case-insensitive. `tools` limits a rule to other tools (default `Bash`; `mcp__*` and `*` work as wildcards). The app writes the file atomically with mode 0600, keeps a last-known-good copy, adds new catalog entries on start, and migrates the version 1 format.

The policy only sees the text of tool calls. It is a speed bump against the usual risky commands, not a sandbox: a script file, another language or an alias can do the same thing without matching a pattern.

## Hook installation

There are two ways to connect Claude Code.

**settings.json.** `earshot-hook --install` (or "Install hooks" in the panel or the gear menu) adds an entry for each of these events to `~/.claude/settings.json`, or `$CLAUDE_CONFIG_DIR/settings.json` when that variable is set:

`SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `PermissionDenied`, `Notification`, `Stop`, `StopFailure`

- The hook command is the absolute path of `Contents/MacOS/earshot-hook` inside the app bundle. If the app moves, the installer reports the hooks as outdated and offers to reinstall them.
- `PermissionRequest` and `PreToolUse` get a timeout of 86400 seconds, so a request can wait as long as you need. Every other event gets 10 seconds.
- Entries are recognised by the `earshot-hook` marker in the command. `--uninstall` removes only those and leaves your other hooks alone.
- The first time Earshot writes the file it keeps a copy of the original next to it as `settings.json.earshot-backup` (mode 0600).

**Plugin.** `.claude-plugin/marketplace.json` makes this repository a plugin marketplace with one plugin, `earshot`. Its `plugin/hooks/hooks.json` registers the same events and timeouts, all pointing at `plugin/scripts/earshot-hook.sh`. That shim:

- looks for `Earshot.app` in `~/Applications`, then `/Applications`, and `exec`s its `earshot-hook`
- does nothing (reads stdin and exits 0) when the app is not installed
- also does nothing when `settings.json` already contains Earshot's hook path, so events are not delivered twice

`--status` prints `installed`, `outdated`, `viaPlugin` (when `enabledPlugins` has `earshot@earshot`) or `notInstalled`.

The hook itself does nothing when `EARSHOT_DISABLE=1` is set. `EARSHOT_RECORD=<file>` appends every raw hook payload to that file, which is handy for collecting test fixtures.

## Wire protocol

One JSON object per line over the unix socket `~/Library/Application Support/Earshot/earshot.sock`. The `EARSHOT_SOCKET` environment variable overrides the path (used by tests). Lines longer than 16 MB are dropped.

Client to app, `WireMessage`:

```json
{"v":1,"kind":"event","agent":"claude","pid":4242,"tty":"ttys002","term":"iTerm.app","payload":{...raw hook stdin...},"policy":null}
```

- `kind` is one of:
  - `event`: everything that does not wait for an answer. The hook writes its line and exits
  - `request`: a `PermissionRequest`, or a `PreToolUse` that matched an Ask rule, from a process that has a tty. The hook waits for a `Reply`
  - `query`: sent by `earshot-hook --list`, with `pid` 0 and a `null` payload. The app answers with one line holding a JSON array of `SessionSnapshot` and closes the connection
  - `debug`: sent by `earshot-hook --simulate`, with a payload like `{"simulate":"approval"}`. The app shows a fake pill marked "Simulated"; a simulated approval is never answered to anyone
- `pid` is the nearest `claude` ancestor of the hook process, 0 if none was found
- `tty` is that process's controlling terminal, like `ttys002`
- `term` is `$TERM_PROGRAM`
- `payload` is the hook's stdin, unchanged
- `policy` is the matching policy rule for `PreToolUse` (`id`, `name`, `action` `ask` or `block`, optional `reason` and the matched `command`), or absent

App to hook, only for requests, `Reply`:

```json
{"decision":"allow"}
```

`decision` is one of `allow`, `always`, `deny`, `pass`, with an optional `message`. The app writes the line and closes the connection.

`SessionSnapshot`, one per session in the reply to a query:

```json
{"pid":4242,"tty":"ttys002","project":"earshot","cwd":"/Users/me/earshot","status":"permission","title":"Fix the build","activity":"Bash make app","lastMessage":null,"seconds":312,"pending":1}
```

`status` is the display status (`permission`, `question`, `error`, `waiting`, `stalled`, `working`, `idle`, `unknown`), `seconds` is the time since the status last changed, `pending` the number of open requests. `earshot-hook --list` renders these as a table with the columns STATUS, PROJECT, FOR, TTY and NOW.

## Sessions

A session is keyed by `pid:<claude pid>`: one terminal runs one `claude` process. `/clear` changes the Claude `session_id` but keeps the same row (a `SessionEnd` with reason `clear` or `resume` does not remove it). Hook events without a `claude` ancestor fall back to a key based on `session_id`.

The process scanner looks for `claude` processes every 3 seconds with libproc. It adds sessions that have not sent any hook yet (status `unknown`) and removes sessions whose process has exited. A real `SessionEnd` also removes the row.

### Titles from Claude Code's local files

Claude Code has no documented way to read a session's title, so `ClaudeMetaReader` (`Sources/EarshotCore/ClaudeMeta.swift`) reads two undocumented local files. This is best effort and can break with any Claude Code update; when it fails, rows fall back to the first prompt line and the folder name.

- `~/.claude/sessions/<pid>.json` (or under `$CLAUDE_CONFIG_DIR`): the session id, folder, name and name source, and a busy or idle status. The file is ignored if its `pid` or process start time does not match the running process
- the tail of the transcript `~/.claude/projects/<folder>/<session id>.jsonl`: the last 256 KB, then the last 2 MB if needed, searched for the newest `ai-title` entry. The result is cached per session and the file is only read again when its size or modification time changed, at most every 30 seconds

The row's title is the first of: a name the user set with `/rename` (name source `user`), the generated `ai-title`, a name whose source is not `derived`, the first line of the first prompt. The folder path goes underneath; without a title the folder name is the main label.

For sessions without hooks, the busy or idle status from the session file is used as working or waiting, so they are not stuck on "No data yet".

## Status machine

The reducer lives in `Sources/EarshotCore/SessionStore.swift` and is a pure function of events and time, which keeps it easy to test.

| Status | Entered on |
|---|---|
| unknown | seen by the process scanner only |
| idle | `SessionStart`, or a pending request interrupted with Esc |
| working | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` |
| stalled (derived) | working, and no event for a while (5 minutes by default, configurable in Settings) |
| waiting | `Stop`, `Notification` `idle_prompt` |
| permission | `PermissionRequest`, `Notification` `permission_prompt` |
| question | `PreToolUse` for `AskUserQuestion`, elicitation notifications |
| error | `StopFailure` (rate limit, API error) |

A `waiting` session is "unseen" until you click it, which turns "Ready for review" into "Idle".

The UI folds these into three looks of the session's spark, so status never depends on telling colors apart:

| Look | Statuses | Spark | Label (`StatusPhrase`) |
|---|---|---|---|
| working | working | white, rotating | "Working" |
| working, but silent | stalled | white, still, slowly breathing | "No activity" |
| needs you | permission, question | clay, hopping, with an expanding ring | "Needs approval", "Needs an answer" |
| needs you | waiting (unseen), error | clay, hopping, no ring | "Ready for review", "Stopped" |
| resting | waiting (seen), idle, unknown | grey, still | "Idle", "Interrupted", "No data yet" |

Labels carry the time in that state ("Needs approval · 5 min"), except for errors and unknown sessions. Sessions are ordered by urgency: permission, question, error, waiting, stalled, working, idle, unknown. In the panel, sessions that need you come first inside a group, and groups holding such a session come first.

Pending requests:

- a `PermissionRequest`, or a `PreToolUse` that matched an Ask rule, adds a card and keeps the hook connection open
- clicking Allow, Always or Deny (or ⌘↩ / ⌘⌫) sends the reply and removes the card; new cards ignore input for 400 ms
- a matching `PostToolUse`, `PostToolUseFailure` or `PermissionDenied` means the user answered in the terminal: the card goes away and the hook gets `pass`
- `Stop`, `StopFailure`, `UserPromptSubmit` and `SessionEnd` cancel every card of that session with `pass`
- the hook connection closing before a reply means Esc was pressed: the card goes away and the session becomes idle with "Interrupted"
- a `PreToolUse` that matched a Block rule does not add a card; it sets the activity to "Blocked · <rule>" and raises the Blocked pill
- a `permission_prompt` notification never cancels a card, and one that arrives shortly after a request was settled does not bring the session back to "Needs approval"
- if the `claude` process dies, its cards are answered with `pass` and the row is removed

## Notch and panel

- The notch area is a borderless panel drawn pure black so it blends with the hardware notch (or a glass island on macOS 26 when Settings > Island style is Glass). Its left ear shows a spark (clay with a ring when anything needs you) with a badge counting missed notifications; the right ear shows one small spark per session, up to five and then "+N".
- Two states: the notch and the panel. Resting the pointer on the notch for about 180 ms opens the panel; a panel opened this way closes about 400 ms after the pointer leaves both the notch and the panel, unless a request card, a drag or a group rename is in progress, or the panel has keyboard focus from a click or ⌃⌥C.
- When the panel is closed, alerts grow the notch into a two-row pill. They form a stack (`NotchState.alertStack`): approvals first, then a critical memory alert, blocked commands, finished sessions (newest first) and a memory warning. The front pill is shown, up to two more peek out underneath with a "+N" count, and hovering fans them out.
  - approval: the session, the command, Deny and Allow, plus a "Policy · <rule>" label for policy asks; stays until answered
  - finished: shown when a session settles into "Ready for review" after working or waiting on you (`FinishRule`), with Later and Open; hides after 8 s
  - blocked: the rule and the command, with Details (opens the panel at that session) and OK; hides after 6 s
  - memory: see below; hides after 12 s
  - an alert never hides while the pointer is over it; buttons ignore clicks for 400 ms
- Alerts that hide on their own, and finished or blocked alerts still waiting when the panel opens, go to the Missed list (at most 20) at the top of the panel.
- The panel floats below the notch as macOS glass and holds the Missed list, the request card, the sessions grouped into modules, and a footer with the memory button and the gear menu.
- On a display without a notch the island becomes a small pill at the top center. Settings choose between the built-in display and the main display.
- ⌃⌥C toggles the panel from anywhere (a Carbon hot key, no accessibility permission needed).

## Groups

`GroupStore` (`Sources/EarshotCore/Groups.swift`) keeps a list of groups, each with a name, one of 9 colors (`GroupColor`), its member sessions, remembered folders and a collapsed flag. It is saved as JSON to `~/Library/Application Support/Earshot/groups.json`.

- Dropping a session onto another creates a group with the next preset name and color (Work, Study, Research, Open Source, Personal, Side Project, Ops, Misc). The naming card offers the first four as chips.
- Members are stored by Claude `session_id` and by `pid:` key, so a row keeps its group across `/clear`. Dead `pid:` keys are pruned.
- Adding a session also remembers its folder. A session without an explicit group joins the group whose remembered folder is the longest prefix of its working directory. The home folder and `/` are never remembered.
- A session belongs to at most one group. Sessions without a group are shown under "Ungrouped".

## Memory and CPU

`UsageSampler` (`Sources/EarshotCore/Usage.swift`) reads, with `sysctl`, Mach host statistics and `proc_pid_rusage`:

- total, used and compressed memory, swap usage and the memory pressure level (normal, elevated, critical)
- overall CPU load, from the difference between two samples
- for every `claude` process, the resident memory and CPU of that process and all of its descendants, which covers MCP servers and tool processes; plus the total over all sessions

The Memory and CPU module samples every 2 seconds, and only while it is open (`AppModel.setUsageVisible`).

### Memory alerts

`MemoryWatch` (`Sources/EarshotCore/MemoryWatch.swift`) reads only the system-wide figures every 10 seconds. It raises a warning when macOS reports memory pressure or swap is more than 80% full (it clears below 70%), and a critical alert on critical pressure. The same level does not fire again within 10 minutes. The alert lists the Claude sessions by memory with the three biggest child processes of each, named by their script for `node`, `python`, `bun` and similar runtimes.

The pill offers Stop for the biggest child process of the top session. `AppModel.stopProcess` sends `SIGTERM` only after a second click (Confirm), and only if `MemoryWatch.isStoppable` agrees: the pid is greater than 1, it is not Earshot itself, it is not one of the sessions' own `claude` processes, and it is a descendant of one of them. Anything else is refused.

Nothing from either sampler is stored.

## Terminal jumping

The jumper (`Sources/EarshotApp/System/TerminalJumper.swift`, with the scripts in `Sources/EarshotCore/JumpScript.swift`) runs off the main thread:

1. If the `claude` process runs under tmux (a `tmux` ancestor, or `$TERM_PROGRAM` is `tmux`), it finds the pane whose tty matches, selects that window and pane, picks the most recently active tmux client (switching it to that session if no client shows it), and then focuses the terminal that shows that client.
2. Otherwise it walks up the process tree to the app that hosts the session. For Terminal.app and iTerm2 an AppleScript selects the window and tab whose tty matches.
3. For any other host app, or if the script finds nothing, the host app is activated.

AppleScript needs the Automation permission, which macOS asks for on first use. The prompt text comes from `NSAppleEventsUsageDescription` in `Resources/Info.plist`.

## App bundle

`scripts/bundle.sh` builds both products and assembles:

```
Earshot.app/Contents/
  Info.plist            version injected from VERSION
  MacOS/Earshot
  MacOS/earshot-hook
  Resources/AppIcon.icns
```

Bundle id `io.github.knqzx.earshot`. The hook binary is signed first, then the bundle, and the result is checked with `codesign --verify --strict`. Builds are signed ad-hoc (`codesign --sign -`), except on a machine where `make signing-identity` created the self-signed "Earshot Local" certificate in the login keychain (and not in CI): then that identity is used, so macOS keeps the Automation permission across rebuilds. `UNIVERSAL=1` builds arm64 and x86_64. The icon is drawn by `scripts/make-icon.swift` with CoreGraphics.

## Verified Claude Code behaviour

Claude Code 2.1.309 with `--model haiku`, driven in a real pty by `Tests/E2E/policy_e2e.py`: a temp git repo with a local bare remote, a temp policy file (`EARSHOT_POLICY`), a test socket (`EARSHOT_SOCKET`) answered by a small harness instead of the app, user settings left out with `--setting-sources project,local`. The prompt asks Claude to run `git push origin main`. Hook timeouts are 86400 s for PreToolUse and PermissionRequest, as in a real install.

| mode | rule on git push | harness answer | what happened |
|---|---|---|---|
| manual (default) | ask | allow after 3 s | the hook held the tool until the answer, PostToolUse came 0.1 s after it, the push ran, no terminal dialog, no PermissionRequest |
| manual (default) | ask | deny after 3 s | the push did not run, no PostToolUse, the turn ended |

These two rows were run against the build in this branch. The rows below come from the same day and the same Claude Code version, run with the hook build from just before the review fixes (same wire protocol, same gate):

| mode | rule on git push | harness answer | what happened |
|---|---|---|---|
| acceptEdits, auto, bypassPermissions, dontAsk | ask | allow after 5 s | same as manual: held until the answer, push ran, no dialog |
| plan | ask | allow | Claude did not run the command in plan mode, so no PreToolUse for it |
| manual, auto, bypassPermissions | ask | deny | push did not run |
| manual, auto, bypassPermissions | block | none needed | the hook answered deny at once without asking the app, push did not run |
| manual, acceptEdits, auto, bypassPermissions, dontAsk | ask, and native `permissions.allow: ["Bash(git push:*)"]` | pass | Claude showed its own dialog ("Hook PreToolUse:Bash requires confirmation") and fired PermissionRequest in every mode; answering allow there ran the push |
| manual, auto, bypassPermissions, dontAsk | same as above | pass, then no answer to PermissionRequest | nothing ran for 30 s in any mode; auto mode did not approve on its own |

Not verified live: deny and block in acceptEdits, dontAsk and plan; partial approvals (`cd x && git push` approved in the notch, where the hook prints nothing and leaves the rest to Claude Code) are covered by unit tests only. bypassPermissions needs `skipDangerousModePermissionPrompt` in the test settings to get past its warning.

## Threat model

Earshot can answer permission prompts and hold or block tool calls, so it is a security-relevant tool even though it is small. [SECURITY.md](SECURITY.md) has the full version.

What it protects against:

- **Other users on the same Mac.** The socket lives in a 0700 directory, the socket file is 0600, and the server checks the peer's uid with `getpeereid` and drops connections from any other user. In the other direction the hook checks that it is talking to the Earshot app from its own bundle. `policy.json` is written with mode 0600.
- **Accidental approval.** Nothing is allowed without a click on Allow or Always, or ⌘↩ while the panel has focus. New buttons ignore clicks and shortcuts for 400 ms. Claude Code's own deny and ask rules still apply to everything Earshot answers.
- **Earshot breaking Claude Code.** Any failure in the hook (app not running, socket missing, unreadable input) ends in exit 0: permission requests go back to the terminal dialog, policy asks fall back to `ask`, and Block rules are answered by the hook alone.
- **Claude editing the guard.** A built-in rule asks before Claude edits Earshot's own files or Claude Code's settings.
- **Stopping the wrong process.** Stop in a memory alert only reaches processes started by Claude sessions, never the sessions' `claude` processes or unrelated processes.
- **Data leaving the machine.** There is no network code to send anything; CI checks for it.

What it does not protect against:

- **Malware running as your user.** A process with your uid can edit `~/.claude/settings.json` or `policy.json` directly, drive your terminal and talk to the socket, including asking for the session list. Earshot does not add a boundary against that, and cannot.
- **An agent that wants around the policy.** Rules match command text. The same action can be written in ways no pattern catches.
- **Changes in Claude Code.** Titles come from undocumented files, and the permission flow relies on the hook behaviour described above.
- **A modified app bundle.** Ad-hoc signing proves nothing about who built the binary. Build from source or check the release checksum if that matters to you.
