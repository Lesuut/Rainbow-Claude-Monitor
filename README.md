# Rainbow Claude Monitor

**A Claude Code monitor for Windows: usage limits, active sessions, CPU and RAM
across several Claude accounts, on one local dashboard.**

Rainbow Claude Monitor is a small local web panel for your second screen — a
Claude Code usage monitor that tracks the 5-hour and weekly limit of every
account you have, shows which sessions are working and which are waiting for
you, watches the machine's CPU and memory, and launches any account with one
button. No Node, no Python, no cloud: Windows PowerShell and a browser.

<table>
  <tr>
    <td width="50%"><img src="docs/screenshot-dark.jpg" alt="Claude Code usage monitor, dark theme: 5-hour and weekly limit bars for three Claude accounts, with CPU and RAM gauges"></td>
    <td width="50%"><img src="docs/screenshot-light.jpg" alt="Claude Code monitor, light theme: multiple Claude accounts with live session status on a local dashboard"></td>
  </tr>
  <tr>
    <td align="center"><b>night</b></td>
    <td align="center"><b>day</b></td>
  </tr>
</table>

The same panel: the theme is not a switch you flip, it drifts along with sunset
in your city.

## Why monitor multiple Claude accounts

If you run several Claude accounts (personal, second personal, work), the only
way to find out where you still have headroom is to open a window and type
`/status`. And once four windows are open and all of them are busy, you cannot
even tell which one is still thinking and which is already waiting for you.

The panel answers all of that without being asked:

- how much of the 5-hour and the weekly window is spent on **each** account;
- when the window resets;
- which sessions are **working** right now and which are **waiting for input**;
- whether the machine itself is choking (CPU / RAM);
- and it launches the account you need with one button, painting its window in
  that account's colour right away.

It is built to sit in the corner of a spare monitor and never ask for attention:
it does not scroll, it slides from the light palette into the dark one as the
sun goes down, and a card blinks briefly the moment its Claude finishes a turn.

## What it does

| | |
|---|---|
| **Limits** | `5H` and `WEEK` bars per account: percentage, time left until the reset (`2h 8m left`), `free` once the window has reset |
| **Freshness** | when the live request fails, the card says `cache · 4h ago` — the numbers are stale and it does not hide that |
| **Live status** | sees running Claude Code sessions: working / waiting for input, and a card blinks when its Claude has finished a turn |
| **Machine** | rainbow arcs for CPU and RAM load, thread count, used / total memory |
| **Colours** | every account gets an accent out of the same nine `/color` offers; click the dot to change it |
| **Launch** | the button starts the account's launcher, answers the "do you trust this folder" prompt and paints the window |
| **Themes** | light / auto / dark; auto drifts with sunrise and sunset at your coordinates |
| **No dependencies** | Windows PowerShell 5.1 and a browser. No Node, no Python, nothing to install |
| **Local** | listens on `127.0.0.1` only, looks nowhere else, collects nothing |

## FAQ

### How do I monitor multiple Claude Code accounts at once?

Every account gets one entry in `accounts[]`, pointing at its own
`CLAUDE_CONFIG_DIR` (`~/.claude`, `~/.claude_work`, and so on). The panel then
polls each of them side by side, so one screen answers "which account still has
headroom" without opening a window and typing `/status`.

### Where do the usage numbers come from?

From Claude Code's own OAuth token for each account: a live request for the
5-hour and weekly windows, falling back to the figures Claude Code caches
locally when the request fails. Nothing is stored and nothing is sent anywhere
else — see [How it works](#how-it-works).

### Does it work with a single Claude account?

Yes. On the first run it writes a `config.json` with one account pointing at
`~/.claude`, and the panel is a plain Claude Code usage monitor with one card.

### Is there a version for macOS or Linux?

Not yet. Reading the limits is portable, but the Launch button and the window
painting go through the Windows console API (`WriteConsoleInput`).

### How is it different from a CLI usage monitor?

It watches accounts rather than a terminal: several at once, next to live
session state (working / waiting for input) and the machine's CPU and RAM, in a
browser tab that is meant to sit on a second monitor all day.

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (ships with the OS);
- Claude Code installed for at least one account;
- a browser.

No admin rights: the `127.0.0.1` prefix is not a reserved URL namespace.

---

## Installation

Get the code first — either way works:

```powershell
git clone https://github.com/Lesuut/Rainbow-Claude-Monitor.git
cd Rainbow-Claude-Monitor
```

or download the ZIP from the repository page and unpack it anywhere. Nothing is
installed and nothing is registered: the folder is the whole program.

Then pick one of the two paths below — hand the setup to Claude, or write the
config yourself.

### Option 1: just ask your own Claude to set it up

The fastest path. Open Claude Code in the folder you just cloned and say
something like:

> Read README.md and PROJECT.md in this folder. Find every Claude Code account
> on this machine (directories like `~/.claude*`, plus the shortcuts and .exe
> launchers on the Desktop and in `%USERPROFILE%`), write a `config.json` for
> them following `config.example.json`, put in my coordinates for the theme (my
> city is Kyiv), give each account a different colour, start the server and
> check that the panel opens and shows limits for all accounts. If any account
> falls back to the cache instead of live data, look at `/api/debug` and tell me
> why.

It will map the directories into `accounts[]`, set the port, theme and
coordinates, run `server.ps1` and show you the result. From then on you can keep
asking it: "add a fourth account", "move it to port 9000", "make the theme
always dark", "put a shortcut in startup".

### Option 2: set it up by hand

Start the server:

```powershell
powershell -ExecutionPolicy Bypass -File server.ps1
```

On the first run `config.json` writes itself — one account pointing at
`~/.claude`. The panel opens at <http://127.0.0.1:8777>.

After that you edit `config.json` and restart the server. The full sample with
every key and a comment on each is `config.example.json`.

#### Accounts

The one thing you really have to configure is `accounts[]`. One entry per
account:

```json
{
  "id": "personal1",
  "label": "Claude Personal 1",
  "configDir": ".claude_personal",
  "launcher": "Claude Personal 1.exe",
  "workingDir": "C:\\Projects",
  "accent": "blue"
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | short unique slug, used by the API |
| `configDir` | yes | the account's `CLAUDE_CONFIG_DIR`: an absolute path, or one relative to `%USERPROFILE%` |
| `label` | no | the name on the card |
| `launcher` | no | the .exe or shortcut the Launch button starts: an absolute path, or a name looked up on the Desktop, in `%USERPROFILE%` and in `PATH`. Omit it and the card simply has no button |
| `launchArgs` | no | array of arguments |
| `workingDir` | no | the folder the window opens in; `%USERPROFILE%` by default |
| `accent` | no | the window's colour: `red orange yellow green cyan blue purple pink default` |

**Finding `configDir`.** With a single account it is `.claude`. Several accounts
are kept apart by `CLAUDE_CONFIG_DIR` in their launchers; list what you have:

```powershell
Get-ChildItem $env:USERPROFILE -Directory -Filter ".claude*" | Select-Object Name
```

A real account directory contains `.credentials.json` and `.claude.json`.

#### Everything else

| Key | Default | What it does |
|---|---|---|
| `title` | `Rainbow Claude Monitor` | text in the browser tab and the panel header |
| `port` | `8777` | local port |
| `openBrowser` | `true` | open the browser when the server starts |
| `location` | Kyiv | coordinates for the sunrise/sunset lookup; `null` falls back to 06:00 / 21:00 local |
| `ui.columns` | `"auto"` | cards per row: a number, or `auto` (1–3 → one row, 4+ → rows of three) |
| `ui.theme` | `"auto"` | startup theme: `light`, `dark`, `auto`. The header toggle overrides it and is remembered per browser |
| `ui.duskMinutes` | `45` | length of the fade between the day and night palettes around sunset |
| `ui.refreshMs` | `1000` | how often the page asks for fresh numbers |
| `ui.showMachine` | `true` | show the CPU / memory row |
| `ui.showSevenDay` | `true` | show the weekly bar |
| `ui.hotPercent` | `90` | percentage at which a bar turns red |
| `ui.accents` | `{}` | your own RGB for the nine names: `{ "blue": { "day": [58,110,168], "night": [74,142,214] } }` |
| `usage.source` | `"auto"` | `auto` — live request with a fallback to the cache; `api` — live only; `cache` — never leave the machine |
| `usage.liveOkSec` | `120` | seconds between live polls of a healthy account |
| `usage.liveBadSec` | `600` | back-off after a failed poll |
| `launch.autoColor` | `true` | paint the window after launching it |
| `launch.trustPromptKeys` | `"down,enter"` | keys sent to answer "Do you trust this folder?"; `""` disables it |
| `launch.waitSec` | `90` | how long to wait for the launched window to appear |
| `launch.trustPromptText` | `"trust"` | text the prompt is recognised by — the keys go the instant it is on screen, and not at all if it never shows; `""` waits `readyMs` blind instead |
| `launch.trustWaitMs` | `4000` | how long that text is waited for |
| `launch.pollMs` | `120` | gap between two looks for the window that just opened |
| `launch.readyMs` | `500` | blind wait before the keys, used only when `trustPromptText` is `""` |
| `launch.keyDelayMs` | `90` | gap between the trust-prompt keys |
| `launch.settleMs` | `150` | wait after the session file appears, before `/color` is typed |

Command-line arguments override the config for one run, which is what a second
copy of the panel needs:

```powershell
powershell -ExecutionPolicy Bypass -File server.ps1 -Port 8778 -NoBrowser
```

## Running it and starting it at logon

`Rainbow Claude Monitor.bat` starts the server minimised; the browser is opened
by the server itself when `openBrowser: true`. To have the panel come up when
you log in, drop a shortcut to that .bat into startup:

```powershell
explorer shell:startup
```

Double-clicking it again later costs nothing: the server checks the port first,
and when the panel is already running it simply opens the browser at it.

---

## How it works

| File | Role |
|---|---|
| `server.ps1` | HTTP server on `HttpListener`: serves the page and the JSON, fetches the limits |
| `index.html` | the whole face: gauges, cards, themes, colours |
| `config.json` | your settings (kept out of git) |
| `config.example.json` | the sample with every key and a comment on each |
| `Rainbow Claude Monitor.bat` | starts it minimised, fit for startup |
| `poke.ps1` | writes text and keys into another process's console (`WriteConsoleInput`), and can wait for a prompt to be on screen first |
| `launch-color.ps1` | waits for the window that just opened, answers the trust prompt, asks for the paint |
| `.cache/poke.dll` | `poke.ps1`'s console interop, compiled once (state, kept out of git) |
| `colors.json` | the current colour of each account (state, kept out of git) |
| `PROJECT.md` | the long version: why every piece is the way it is |

**Where the limits come from.** The primary source is `GET
https://api.anthropic.com/api/oauth/usage` with the account's own OAuth token,
read from `<configDir>/.credentials.json` at request time — never stored, never
logged. The fallback is `cachedUsageUtilization` inside
`<configDir>/.claude.json`, which only Claude Code itself refreshes (on
`/status`), so it is often a day old and the card is then labelled
`cache · N ago`.

**Where the session state comes from.** `<configDir>/sessions/<pid>.json` is a
registry Claude Code keeps itself. A session counts as alive only while its pid
is still among the running processes and the record is younger than 12 hours.

**Why the panel holds the colour, not Claude.** `/color` changes the colour only
in the memory of the running window and writes it nowhere — not to
`settings.json`, not to `sessions/*.json`. So the choice lives in `colors.json`,
and the panel sends `/color` into one specific window by pid.

The reasoning behind each decision is in `PROJECT.md`.

## API

- `GET /` — the page
- `GET /api/config` — the `ui` block for the client
- `GET /api/stats` — `{ cpu, ram, host, accounts[] }`, each account carries `source: api|cache`
- `GET /api/debug` — what the live poll returned (codes and errors, no tokens)
- `POST /api/refresh` — drop the live cache and re-fetch
- `POST /api/color?id=&name=[&pid=]` — paint an account's windows
- `POST /api/launch?id=` — start an account's launcher

## Privacy

The server listens on `127.0.0.1` only, and the single address it reaches out to
is `api.anthropic.com` for your own limits (plus one sunset lookup a day). OAuth
tokens are read on the fly and never reach the logs, `/api/debug` or the page.
`config.json` and `colors.json` are excluded from git so the paths and layout of
your accounts stay off the repository.

## Caveats

- `/api/oauth/usage` is an internal Claude Code endpoint, not a public API: it
  can change without notice. Any error quietly drops the account to the cache,
  the panel keeps working, and the reason shows up in `/api/debug`.
- The Launch button and the painting are Windows-specific: they write into
  another process's console through `WriteConsoleInput`.
- When the panel is started from inside Claude Code itself, the server strips
  `CLAUDE*`, `AI_AGENT` and `NO_COLOR` from its own environment — otherwise a
  new window inherits the wrong account and never gets painted.

## Ideas for later

- a sound or a notification when a limit crosses 90%
- refreshing the token with `refresh_token` once the access one expires
