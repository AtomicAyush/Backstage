# Backstage

**Give AI agents their own screen on your Mac, so you can keep working while they use apps.**

When Claude or another agent uses your computer the usual way, it takes over your screen: it
moves your cursor, brings windows to the front, and types into whatever has focus. Backstage gives
each agent an invisible display of its own instead. The apps it opens live there, and its clicks
and keystrokes go straight to those apps. Your cursor, your keyboard, and your frontmost app are
never touched.

```
 You ──▶ your display ──▶ your apps            (nothing changes for you)

 Agent ──▶ Backstage (MCP) ──▶ invisible agent screen ──▶ the agent's apps
                                     ▲
              Backstage menu ────────┘  watch · pause · take over · answer
```

It's a small Swift CLI that speaks the [Model Context Protocol](https://modelcontextprotocol.io),
plus a menu-bar app for keeping an eye on things. It works with any agent that can launch a
local MCP server, including Claude Code, the Claude desktop app, Codex, and Cursor.

## Install

You need macOS 14 or later and Xcode (for Swift).

```bash
git clone git@github.com:AtomicAyush/Backstage.git
cd Backstage
./install.sh
```

This builds Backstage, installs `backstage` to `~/.local/bin` and **Backstage.app** to
`/Applications`, and adds Backstage to the agents it finds (Claude Code, the Claude app, Codex).
It never removes anything else from their settings. Use `./install.sh --no-setup` to skip that
step, then connect agents yourself with `backstage setup claude-code` (or `claude-desktop`,
`codex`).

**Permissions.** macOS charges permissions to the app that *starts* Backstage, which is your
terminal, Claude, or Codex. That app needs both of these:

- **Accessibility**, to operate the agent's apps
- **Screen Recording**, so the agent can take screenshots of its screen

Run `backstage doctor` to see what's missing. The Backstage menu-bar app asks for Screen Recording
separately, and only to show you live views.

Then try it:

```bash
backstage try
```

`backstage try` opens TextEdit and Calculator on an agent screen, types, presses ⌘-shortcuts, and
clicks buttons, then checks that your frontmost app never changed.

## Using it

Restart your agent after installing, then just ask:

> Open Numbers in Backstage and make a table of my last five invoices.
>
> Use Backstage to check the Golden Gate Bridge's Wikipedia page and tell me when it opened.

The agent creates its screen on first use and removes it when it calls `close_screen` or exits.
Apps the agent opened are quit at the end. An app that won't quit (say it's asking about unsaved
changes) is moved onto your screen instead, so nothing is lost.

### What the agent can do

| Tool | What it does |
| --- | --- |
| `open_app` | Open a Mac app on the agent's screen |
| `open_url` | Open pages in the agent's own browser: a separate Chrome-family instance with its own profile, never yours |
| `screenshot` | See the agent screen (with your menu bar strip blanked out) |
| `read_ui` | Outline the interface from Accessibility, with numbered refs for every control |
| `click`, `type_text`, `press_key`, `scroll`, `drag`, `hover` | Act, by ref or by coordinates |
| `use_menu` | Choose a menu command, e.g. `["File", "Export as PDF…"]` |
| `list_windows`, `focus_window`, `quit_app` | Manage its windows and apps |
| `ask_user` | Ask you to step in (sign in, approve something) and wait for you |
| `wait`, `close_screen` | Pace itself, and clean up |

### The Backstage menu

While an agent has a screen, a theatre-masks icon sits in your menu bar. From it you can:

- **Watch** a live view of the agent's screen (also `backstage watch`)
- **Pause** the agent: its next actions are refused until you resume
- **Take Over**: the agent's windows move onto your screen so you can use them with your real
  keyboard and mouse; **Give Back** returns them
- **Answer** an agent that called `ask_user`, optionally with a message

The icon turns orange and you get a notification when an agent needs you.

## How it works

- **The screen** is a virtual display created with CoreGraphics' `CGVirtualDisplay`, the same
  mechanism behind Sidecar. macOS treats it like a real monitor, so the agent's apps keep drawing,
  Accessibility sees them, and ScreenCaptureKit can capture them. The display belongs to the
  agent's process and disappears with it.
- **Input** is posted straight to the target app with `CGEvent.postToPid`, which never moves your
  cursor or changes which app is frontmost. Backstage fills in what the WindowServer normally adds
  on its way through (which window the event is for, and where inside it), and tells native apps
  they're active using the same AppKit event the system sends on a real switch. Your menu bar
  and keyboard focus stay with you.
- **Controls** are pressed and focused through Accessibility wherever possible, so clicks by ref
  can't miss. For web pages, a click finds the element under the point and presses it, which
  gives the page a full, trusted `pointerdown → click` sequence.
- **Guards.** A cursor fence keeps your pointer off agent screens. A focus guard hands focus back
  at once if an agent app pulls itself forward. Backstage also refuses to create a screen while
  none of yours is awake, and never removes a screen while it's the only display (closing the lid
  would otherwise leave it behind).

Backstage uses a few private but long-stable macOS interfaces: the `CGVirtualDisplay` classes,
`CGEventSetWindowLocation`, `_AXUIElementGetWindow`, and some undocumented CGEvent fields. All of
them are looked up at runtime, so a missing one disables a feature instead of crashing.
`backstage doctor` reports on each.

## Limits worth knowing

- **It isn't a sandbox.** The agent's apps run as you, with your files, network, and logins. Use a
  separate macOS account or a VM for anything you don't trust.
- **Apps can still pull themselves forward.** Chrome does this once at launch. Backstage hands
  focus back immediately, but a keystroke typed in that instant can land in the wrong app.
- **Browser tab shortcuts.** ⌘W and ⌘[ don't act while the browser isn't your active app; agents
  use the tab and toolbar buttons instead. Clicks on plain, non-interactive parts of a page may be
  ignored.
- **Agent apps appear in the Dock and ⌘-Tab**, and their notifications still reach you.
- **Your apps stay yours.** If an app is already open on your screen, the agent can't take it
  unless you agree (`take_over`). For the web it uses its own browser.

## Commands

```
backstage mcp                 Run the MCP server (what agents launch)
backstage setup [client…]     Connect to claude-code, claude-desktop, codex (default: all found)
backstage doctor              Check permissions and system support
backstage try                 Live demo that verifies isolation
backstage watch [screen]      Open a live view of an agent screen
backstage cleanup             Remove agent screens left behind by sessions that ended badly
```

Environment: `BACKSTAGE_SIZE=1920x1080` sets the screen size (default 1440×900),
`BACKSTAGE_BROWSER=Brave` picks the browser, `BACKSTAGE_FENCE=0` turns off the cursor fence,
and `BACKSTAGE_DEBUG=1` logs to stderr.

## Development

```bash
swift build          # debug build of everything
swift test           # unit tests (no displays created)
.build/debug/backstage try
./install.sh --build-only   # assemble build/Backstage.app without installing
```

Layout: `Sources/CVirtualDisplay` (the Objective-C display shim), `Sources/BackstageCore`
(screen, input, capture, UI outline, session), `Sources/backstage` (CLI and MCP server),
`Sources/BackstageViewer` (menu-bar app).

Inspired by [SpaceO](https://github.com/ParthJadhav/SpaceO); Backstage is an independent
implementation.
