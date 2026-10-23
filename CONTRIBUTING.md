# Contributing to Earshot

Thanks for helping. Earshot tries to stay small enough that anyone can read all of it before trusting it with their permission prompts. Most of the rules below follow from that.

## Ground rules

- **No dependencies.** No Swift packages, no vendored libraries, no CocoaPods or Carthage. Apple's SDKs only.
- **No network code.** No `URLSession`, `Network.framework`, `CFNetwork`, `NSURLConnection` and no shelling out to `curl`. The only socket is the local unix socket between the hook and the app. `make check-no-network` fails if any of these show up in `Sources/`.
- **Never break Claude Code.** `earshot-hook` must exit 0 whenever something goes wrong and leave the decision to Claude Code: print nothing for permission requests, `ask` for policy asks.
- **Only ever stricter.** The hook must never answer `allow` unless the app sent `allow` after a user click. The policy may hold or block a call, never approve one.
- **Do not touch real user data in tests.** Tests use temporary files for `settings.json` and a temporary socket via `EARSHOT_SOCKET`.
- **Keep it small.** A feature that doubles the code size is probably a different app. Open an issue first if you are unsure.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer, or a Swift 6 toolchain with the macOS SDK. Xcode 26 (Swift 6.2, macOS 26 SDK) adds the Liquid Glass island; CI builds with both

## Build and run

| Command | What it does |
|---|---|
| `make build` | builds both products (`CONFIG=debug` for a debug build) |
| `make test` | runs the unit tests |
| `make app` | builds and assembles `build/Earshot.app`, ad-hoc signed (or with "Earshot Local", see below) |
| `make signing-identity` | creates a self-signed "Earshot Local" code signing certificate in your login keychain, once, so the Automation permission survives rebuilds |
| `make snapshot` | renders every UI state offscreen into `build/snapshots` and refreshes the README screenshots in `docs/media` |
| `make install` | copies the app to `~/Applications`, quits a running copy and opens the new one |
| `make hooks` / `make unhooks` | adds or removes the hooks in `~/.claude/settings.json` using the installed app |
| `make uninstall` | removes hooks, the login agent, the app and its support folder |
| `make loc` | counts the lines of Swift in `Sources/` |
| `make check-no-network` | fails if networking APIs appear in `Sources/` |
| `make icon` | redraws `Resources/AppIcon.icns` from `scripts/make-icon.swift` |
| `make clean` | removes `build/` and `.build/` |

All Swift builds go through `scripts/sbuild`, a thin wrapper around `swift build` / `swift test` that runs at low priority with 4 jobs and holds a lock shared by all git worktrees of the repo, so parallel checkouts do not compile at the same time. Use it (or the Makefile) instead of calling `swift build` directly.

`UNIVERSAL=1 make app` builds for arm64 and x86_64, which is what release builds use.

To try the notch without a real request, run the app and use `earshot-hook --simulate approval` (or `finished`, `memory`, `memory-critical`, `blocked`, `jump`, `burst`). Simulated pills are marked "Simulated" and simulated approvals are never sent to Claude. In debug builds (`make app CONFIG=debug`), the `--trace-hover`, `--trace-panel`, `--trace-stack`, `--trace-finished` and `--trace-approval` flags start the app on sample sessions and print animation timings, which helps when working on motion.

## Code layout

```
Sources/EarshotCore          models, wire protocol, socket server and client, hook runner and output, policy
                             (catalog, matching, shell splitting, store), session reducer, status phrases,
                             Claude Code metadata reader, groups, usage sampling and memory watch,
                             settings.json installer, launch agent, jump scripts
Sources/EarshotHook          the earshot-hook command line tool
Sources/EarshotApp/App       app delegate, settings (General and Policy tabs), hot key, sounds, hook install control
Sources/EarshotApp/Notch     the notch island and panel windows, layout and state
Sources/EarshotApp/Views     SwiftUI views: spark, rows, groups, request card, usage module
Sources/EarshotApp/System    process scanner, terminal jumper, login item
Sources/EarshotApp/Samples   sample sessions used by snapshots and motion traces
Sources/EarshotApp/Snapshot  offscreen renderer for make snapshot
Tests/EarshotCoreTests       unit tests and JSON fixtures
Tests/E2E                    pty driver for end-to-end runs against a real Claude Code
plugin/, .claude-plugin/     the Claude Code plugin and its marketplace file
scripts/                     build wrapper, bundling, signing identity, icon
Resources/                   Info.plist and the app icon
docs/                        design notes, HTML mockups and screenshots
packaging/homebrew           tap formula template
```

The visual design (spark states, colors, sizes) is described in [docs/DESIGN.md](docs/DESIGN.md), with HTML mockups in `docs/design`. UI changes should follow it or update it.

[ARCHITECTURE.md](ARCHITECTURE.md) explains how the pieces talk to each other and what Claude Code does with hooks.

## Code style

- Swift 6 toolchain, Swift 5 language mode
- Let names do the explaining. Avoid comments that restate the code, docstrings on obvious functions, and "ported from" or "TODO" notes. A short comment is fine when the code does something surprising for a reason that is not visible in the code
- Logic that does not need a window belongs in `EarshotCore`, with tests
- Match the formatting of the code around you

## Adding a terminal

Jumping lives in `Sources/EarshotApp/System/TerminalJumper.swift`, and the AppleScript and tmux helpers it uses live in `Sources/EarshotCore/JumpScript.swift`, where they can be unit tested (see `Tests/EarshotCoreTests/JumpScriptTests.swift`). The jumper knows the `claude` process id and its `tty` (like `ttys004`). It walks up the process tree to the app that hosts the session and switches on that app's bundle id; tmux is handled first, then the outer terminal is focused.

To add a terminal:

1. Find its bundle id, for example with `osascript -e 'id of app "WezTerm"'`.
2. Find a way to focus the tab or pane that owns a given tty using only what ships with macOS or with the terminal itself: AppleScript, the terminal's own command line tool, or its URL scheme. No new dependencies and no network calls.
3. Put the script or command builder in `JumpScript.swift` with a test, and add a case for the bundle id in `TerminalJumper.focus`. If the precise jump fails, fall back to activating the app, which is what unknown terminals get today.
4. If you use AppleScript, remember that macOS asks for the Automation permission on first use.
5. Try it by hand with a couple of windows and tabs open, then add a row to the "Supported terminals" table in the README.

## Changing the policy catalog

The built-in rules live in `Sources/EarshotCore/PolicyCatalog.swift`. Each rule has an id, a group, a name, a short description, a default choice and one or more matchers. A few things to keep in mind:

- Rules are Off, Ask or Block; there is no Allow. The policy only ever makes Claude Code stricter
- New rules default to Off. Only `git push`, force push and the rule that protects Earshot's and Claude Code's settings ask out of the box, and changing that should stay a deliberate decision
- Shell matchers are regular expressions run against every part of a split command, case-insensitive. Start them with `PolicyCatalog.cmd` so a full path like `/usr/bin/git` still matches
- Add tests for commands the rule must catch and for close calls it must not catch
- Never make the hook fail open: an error while loading the policy falls back to the last good copy or the defaults, and an error while matching must end in Claude Code's own prompt, never in `allow`

The policy is a speed bump, not a sandbox, and the docs say so. Do not describe a rule as preventing something it only usually catches.

## End-to-end runs against a real Claude Code

Unit tests cover the reducer, the socket and the hook output with recorded payloads. The parts that depend on how Claude Code behaves are checked with `Tests/E2E/drive_claude.py`, which starts a real `claude` in a pseudo terminal, types a prompt and presses keys at set times.

- It writes a temporary settings file with the Earshot hooks and passes it with `claude --settings`, so your `~/.claude/settings.json` is not touched. It runs in a fresh temporary folder unless you pass `--workdir`.
- It uses your own Claude Code login and model `haiku`. A run costs a few cents of your plan's usage.
- Point `--hook` at a built `earshot-hook` and run the app so the hook has someone to talk to. Set `EARSHOT_SOCKET` to a temporary path for both to keep the run away from an installed copy.

```sh
make app
export EARSHOT_SOCKET=/tmp/earshot-e2e.sock
build/Earshot.app/Contents/MacOS/Earshot &
python3 Tests/E2E/drive_claude.py --hook "$PWD/build/Earshot.app/Contents/MacOS/earshot-hook" --keys 6:enter
python3 Tests/E2E/drive_claude.py --hook "$PWD/build/Earshot.app/Contents/MacOS/earshot-hook" --keys 6:esc
kill %1
```

`--keys` takes a comma separated list of `seconds:key` after the prompt is sent, where key is `enter`, `esc` or `none`; adjust the seconds so the key lands while the permission dialog is open. At the end the script prints the work folder and whether the test file was created, and saves the cleaned screen to `.screen.txt` in that folder.

Scenarios verified this way:

- answering the permission dialog in the terminal clears the card in the notch within a second, and the waiting hook exits
- pressing Esc in the terminal kills the hook, and the session shows "Interrupted"

## Pull requests

- One topic per pull request, with a short description of what changed and how you tested it
- `make test` and `make check-no-network` pass
- Commit messages are short plain English, like `Jump to WezTerm panes by tty`
- Update the README, ARCHITECTURE.md and CHANGELOG.md when behaviour changes
- For UI changes, add a screenshot

By contributing you agree that your work is released under the [MIT license](LICENSE).
