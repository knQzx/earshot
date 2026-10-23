# Changelog

All notable changes to Earshot are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.0] - Unreleased

First public version.

### Added

- A Claude-style spark next to the notch for every running Claude Code session, with three looks:
  white and spinning while working, clay and hopping when it needs you (with an expanding ring for
  approvals and questions), grey and still while resting
- Status labels with durations, like "Needs approval · 5 min", "Ready for review" and "No activity"
- Session titles as the main label (your `/rename`, then Claude Code's generated title, then its
  automatic name, then the first prompt line) with the folder path underneath, read best effort from
  Claude Code's local session files
- Two states: the black notch and a glass panel below it; hover, click or ⌃⌥C opens the panel
- Inline approval: the notch grows into a pill with the command, Deny and Allow when a request arrives;
  the full request card in the panel adds Always and a jump to the terminal; new buttons ignore input
  for 400 ms and the terminal dialog stays live
- Finished pill with the first line of Claude's answer, Later and Open
- Notification stack: approvals, finished sessions, memory warnings and blocked commands queue up in
  the notch and fan out on hover; pills that time out go to a Missed list with a count on the notch
- Memory alerts on memory pressure or high swap, naming the Claude session and helper process that use
  the most memory, with Stop (for processes started by a Claude session, after a confirmation) and Open
- Memory and CPU module: memory pressure, compressed memory, swap and CPU, plus memory and CPU of every
  Claude session including its MCP servers and tools, sampled every 2 seconds only while it is open
- Policy: a catalog of risky actions (git, release and deploy, destructive commands, packages, network,
  secrets, edits outside the project) with Off, Ask or Block per rule, and your own rules with `*`
  patterns or `regex:`. By default it asks before `git push`, force pushes and edits to Earshot's or
  Claude Code's settings. Ask holds the tool call in the `PreToolUse` hook until you answer in the notch,
  Block refuses it and shows a Blocked pill. The hook applies the policy even when the app is closed,
  falls back to Claude Code's own prompt when the app cannot be reached, and uses the last good copy or
  the defaults if `policy.json` is broken. The policy never approves anything on its own
- Jump to the terminal: exact tab in Terminal.app and iTerm2, the right pane in tmux, the app itself for
  other terminals, with a hint when macOS Automation permission is missing
- Session groups: drag one session onto another, preset names (Work, Study, Research, Open Source and
  more), 9 colors, remembered folders so new sessions there join on their own
- Claude Code plugin as an alternative to editing `settings.json`:
  `/plugin install earshot --marketplace knQzx/earshot`
- `earshot-hook --install`, `--uninstall`, `--status`, `--version`, `--list` (all sessions as a table)
  and `--simulate` (pills marked "Simulated", for testing)
- The hook checks that the socket peer is the Earshot app from its own bundle before trusting a reply
- Settings with General and Policy tabs: display, island style Black or Glass (macOS 26), launch at
  login, open on hover, finished notifications, auto-open on requests, sounds, minutes until
  "No activity"
- Small pill at the top of displays without a notch
- `make signing-identity` for a stable local signing certificate, so the Automation permission survives
  rebuilds
- Ad-hoc signed app bundle, universal (Apple Silicon and Intel) release builds
- No network code and no third-party dependencies, checked in CI
