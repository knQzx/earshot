# Earshot visual design

Source of truth: the HTML mockups in `docs/design/*.dc.html` (open them in a browser; every value below comes
from them). Language: English only.

## Principles

- the notch stays pure black and seamless with the hardware notch; everything else is macOS glass
- no colored status dots: every session is the Claude spark in a small circle; state is told by the
  spark's motion and tint plus a short text label with a time
- calm and compact: two-line rows, numbers right-aligned in a column, modules with soft rounded corners
- two status colors only: white = working, clay = needs you; everything resting is grey; motion carries the rest

## Tokens

| token | value |
|---|---|
| glass (panel, menu bar) | `NSVisualEffectView` `.hudWindow` or `.popover` material, dark appearance, behind-window blending; SwiftUI `.ultraThinMaterial` on a dark scheme is acceptable. Target look: rgba(30,30,34,0.52) + blur 40 + saturate 1.8 |
| glass outline | 0.5 pt rgba(255,255,255,0.18) + shadow 0 20 50 rgba(0,0,0,0.35) |
| module (group card, usage card, request card) | rgba(255,255,255,0.08), radius 18 (request 20) |
| inset well (code block, avatar fill) | rgba(0,0,0,0.32-0.38) |
| text primary / secondary / tertiary | white / white 58% / white 45-50% |
| clay (needs you) | spark #D97757 on black, #E8957A on glass, labels #FFB38F |
| group colors | blue #0A84FF, indigo #5E5CE6, purple #BF5AF2, pink #FF375F, teal #64D2FF, mint #30D158, yellow #FFD60A, brown #AC8E68, gray #8E8E93 (`GroupColor` cases) |
| type | SF Pro: section 13 semibold, row title 13 semibold, row subtitle 11.5, right column 12 medium + 11, chips 11-12 semibold; SF Mono 12 for commands; tabular digits for numbers |
| radii | panel 26, modules 18-20, rows 14, buttons 14 (pill), small buttons 8 |
| spacing | panel padding 8, gap between modules 6, row height 42, avatar 24 (request header 28) |

## The spark

Original 8-ray asterisk (4 lines through the center, round caps), not Anthropic's logo file. Inside a circle
filled with the inset well color.

Three meta-states, two colors plus motion. Nothing else carries status color (group colors are only labels).

| meta-state | display states | spark | motion | label color |
|---|---|---|---|---|
| working | working | white | spark rotates once per 6 s | white 75% |
| working, but silent | stalled | white 75% | no rotation, slow breathe (opacity 0.45-1, 2.4 s) | white 75% ("No activity") |
| needs you | permission, question | clay #E8957A (#D97757 on pure black) | whole circle hops (3 pt up + small second bounce, every 2.2 s) AND a clay ring expands and fades every 1.8 s | #FFB38F |
| needs you | waiting unseen (ready for review), error | clay | hop only, no ring | #FFB38F |
| resting | waiting seen, idle, interrupted, unknown | white 35% (unknown 25%) | still | white 50% |

Text comes from `StatusPhrase.parts` (label + time). Time goes under the label in the right column.

## Collapsed notch (Collapsed.dc.html, Main.dc.html)

- black shape = hardware notch + ears, 32 pt tall, bottom radius 11
- left ear: the spark circle (20-22 pt), clay spark; when anything needs you it gets the pulsing clay ring
- right ear: one small circle per session (18 pt, #1C1C1E fill, 1.5 pt black separation ring, overlapping
  by 3 pt like an avatar stack) holding a 9 pt spark in its state color and motion (max 5, then "+N")
- two states only: this collapsed notch and the full panel below it. Hovering the notch or its ears for
  ~180 ms opens the full panel (setting "Open on hover", on by default); click and ⌃⌥C toggle it. A panel
  opened by hover closes once the pointer has been outside the notch and the panel for ~400 ms, unless a
  request card is shown, a drag or a group rename is in progress, or the panel took keyboard focus from a
  click or the hotkey (then only a click outside or Esc close it)

## Inline approval (approval-notch.png)

- when a request arrives and the panel is closed, the black island grows down with the shared spring into a
  two-row pill: at least 460 x 76 (wider if the left ear needs it), bottom radius 22, soft shadow
- row 1 sits in the ears at notch height: left the spark circle (22 pt) with the clay ring and hop, the
  project name (13 semibold) and a small group capsule (18 pt, group color 28% fill, light tint text);
  right "+N" in #FFB38F when more requests wait
- row 2 below the notch line: the command or tool summary in SF Mono 12, one line, clipped, white 85%;
  on the right two 26 pt pills: Deny (white 14%) and Allow (white fill, black text)
- buttons ignore clicks for the first 400 ms; clicking anywhere else on the island opens the full panel
  with the full request card (Always and the terminal button live there)
- hover does not open the panel while the approval island is shown, so the pointer can reach the buttons
- opening the panel automatically on a new request is a setting and off by default

## Finished pill (finished-notch.png)

- when a session settles into "Ready for review" (it was working, stalled or waiting on you, it has hooks,
  and you have not looked at it yet) and the panel is closed, the black island grows into the same two-row
  pill as the inline approval (at least 460 x 76, radius 22). Approval pills win; finished pills wait
  behind them, and with several finished sessions the newest is shown with "+N" in #FFB38F
- the grow uses a livelier spring than the rest of the UI (response 0.38, damping 0.72, a small overshoot);
  once it lands, one soft clay glow pulses around the edge and fades out in under a second. No loops
- row 1: spark circle in clay with the hop (no ring), session name (13 semibold), small group capsule;
  right "Done · just now" in #FFB38F, the time counting from when the session finished
- row 2: first line of Claude's last message (white 70%, one clipped line, "Ready for review" if empty);
  right two 26 pt pills: Later (white 14%) and Open (white fill, black text). Both ignore clicks for the
  first 400 ms. Open jumps to the terminal (which marks the session seen); Later only hides the pill, so the
  session keeps hopping in the ears. Clicking elsewhere on the pill opens the full panel
- the pill hides itself after 8 s, but not while the pointer is over it; hover does not open the panel while
  it is shown. Setting "Notify when a session finishes" (on by default); the finish sound plays at the same
  moment when sounds are on

## Panel (Panel.dc.html)

- floats 8 pt below the notch, width 440, glass; the notch itself stays black above it
- header: "Sessions" + count; right: "N needs you" in #FFB38F (only when N > 0)
- each group is a module: header row (7 pt color dot, name, count, optional right note like "1 needs you"
  or "All working", chevron) and its rows; collapsed groups are just the header row
- rows: avatar, project (13 semibold) over task title (11.5, 58%), right column label + time
- sessions that need you sort first inside a group; groups that contain such a session sort first
- a collapsed group shows, right after its name, a mini avatar stack: one 18 pt spark circle per session in
  that group with the same state motion (white spinning, clay hop with or without ring, grey still), instead of
  the plain count
- footer: memory button (chip icon, "12 of 16 GB", chevron) left, gear right

## Request card (Request.dc.html)

- module at the top of the panel: avatar with ring, project name over "Wants to run a command · 2 min"
  (MCP: "Wants to use notion · search"; edits: "Wants to edit main.swift"), group capsule on the right
- inset well with the description (11, 50%) and the command in SF Mono 12
- buttons: Deny, Always (only if available), terminal icon button, spacer, Allow (white pill, black text,
  "⌘↩" hint at 42%); ghost buttons white 14% fill, 28 pt tall pills
- "1 more request · mobile-app" centered below; then the compact session list (dot in group color, project, phrase)

## Groups (Groups.dc.html)

- drag a row onto another row: target highlights (white 10% fill + 1.5 pt white 35% inner ring) and shows
  "Create group" on its right; the dragged row lifts (scale 1.03, slight tilt, deep shadow)
- dropping creates a group via `AppModel.groupTogether`, opens an inline naming module: "New group" label,
  a text field prefilled with the preset name (blue focus ring), 8 color swatches (selected = white ring),
  preset chips Work / Study / Research / Open Source
- drag onto a group header adds to that group; drag out to empty space removes from the group
- right-click a group header: Rename, Color, Collapse, Delete

## Memory and CPU (Usage.dc.html) - the user's favourite, keep it exactly

- clicking the memory button expands a module above the footer (spring): Memory row with
  "Pressure: normal|elevated|critical", a 6 pt segmented bar (used white 92%, compressed white 50%, rest 14%),
  "12 of 16 GB · compressed 5.2 GB · swap 5.6 GB"; CPU row with % and bar; hairline; "All Claude sessions"
  with total memory, CPU and process count
- while open, every row shows its memory and CPU in the right column instead of label/time
- data from `AppModel.usage` (call `setUsageVisible(true/false)` when the module opens/closes)
