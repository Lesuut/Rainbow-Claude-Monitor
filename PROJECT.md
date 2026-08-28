# Rainbow Claude Monitor — design notes

A local HTML panel: machine load plus the limits of every Claude account.
This file is the long version of the README — why each piece is the way it is.

## Why

With several Claude accounts launched from desktop shortcuts (each shortcut
sets its own `CLAUDE_CONFIG_DIR`), you want to see in one glance which account
still has headroom and whether the machine itself is choking.

## Parts

| File | Role |
|---|---|
| `server.ps1` | local HTTP server (`HttpListener`, `127.0.0.1:8777`): serves the page and the JSON |
| `index.html` | the whole face: two round gauges and one card per account |
| `config.json` | everything configurable; `config.example.json` is the annotated sample |
| `Rainbow Claude Monitor.bat` | starts the server minimised (fit for startup) |
| `poke.ps1` | writes text or keys into another process's console (`WriteConsoleInput`) |
| `launch-color.ps1` | waits for the window that just opened, sends Down+Enter, asks for the paint |
| `colors.json` | the current accent of each account |
| `PROJECT.md` | this file |

No external dependencies: Windows PowerShell 5.1 and a browser.

The face is built for a **960×640** screen and never scrolls: `100vh`, a grid of
four rows, `overflow:hidden`. The smallest type on the page is 14px.

## Where the data comes from

### Machine (polled once a second)
- CPU % — `Win32_PerfFormattedData_PerfOS_Processor` (`Name='_Total'`)
- RAM — `Win32_OperatingSystem`: `TotalVisibleMemorySize` / `FreePhysicalMemory`
- Plus: CPU model, core count, uptime, process count

The CIM counter was chosen over `Get-Counter` because it needs no sampling
second — the read is instant, so the gauges move smoothly.

### Claude limits

Two sources, in this order.

**1. Live request (primary).** `GET https://api.anthropic.com/api/oauth/usage`
with the account's OAuth token. The token is read from
`%USERPROFILE%\<config>\.credentials.json` at request time, and is never stored
or logged. Headers:

```
Authorization: Bearer <token>
anthropic-beta: oauth-2025-04-20
Accept: application/json
User-Agent: claude-cli/<ver> (external, cli)
```

Polled every `usage.liveOkSec` seconds per account (2 minutes by default), and
backed off to `usage.liveBadSec` (10 minutes) after an error. `server.ps1`
tries three header sets and remembers the one that worked (`$hdrStyle`). The
response carries `five_hour` / `seven_day` with `utilization` and `resets_at`.

**2. Cache (fallback).** `%USERPROFILE%\<config>\.claude.json`, key
`cachedUsageUtilization` — the same shape plus `fetchedAtMs`. Only Claude Code
itself writes that cache, and only when you type `/status`, so it is often a day
stale. It is used when the live request fails; the page then labels the card
`cache · N ago`.

The `source` field in `/api/stats` says which one answered: `api` or `cache`.
Diagnostics for the live poll live at `GET /api/debug` (response codes and
errors, no tokens).

### Whether Claude is working right now

`%USERPROFILE%\<config>\sessions\<pid>.json` is a registry of live sessions that
Claude Code maintains itself. The fields that matter are `pid`, `status`
(`busy` during a turn, `idle` while waiting for input) and `updatedAt`. Those
files outlive a crashed process, so a session counts as alive only while its pid
is still in `Get-Process` and `updatedAt` is younger than 12 hours. An account
is lit when at least one of its sessions is busy.

### Sunset

`GET https://api.sunrise-sunset.org/json?lat=<lat>&lng=<lng>&formatted=0&date=<today>`
— looked up once a day for the coordinates in `config.json` and handed to the
client as `sun.sunriseMs` / `sun.sunsetMs` in UTC. If the request fails, the
client falls back to 06:00 / 21:00 in the machine's local time.

## Themes

Two palettes of 13 tokens each (`DAY` and `NIGHT` in `index.html`). What is on
screen is always a blend of them: a single `night` number, 0…1, is run through
`lerp` across every token and written into CSS variables each frame. That is why
dusk is a drift rather than a switch.

The modes are a toggle in the header: light on the left, auto in the middle,
dark on the right. The choice lives in `localStorage["sysmon-theme"]`. In auto:
full night before sunrise and after sunset, day in between, with a 45-minute
stretch at each edge. For Kyiv on 28 August (sunset 19:53) that gives 0.00 at
19:53, 0.49 at 20:15 and 1.00 by 20:38.

## Account colours

The idea was to read the colour from the `/color` command inside Claude Code
itself. **Not possible**: it changes the colour only in the memory of the
running window and writes it nowhere. Checked both on disk and in the docs:

- `sessions/<pid>.json` — 20 fields, no colour
- `.claude.json`, `settings.json`, `session-env/<id>/` — nothing
- the statusline receives `session_name`, but the schema has no colour field —
  <https://code.claude.com/docs/en/statusline>
- the request for `color` in `settings.json` is still open —
  <https://github.com/anthropics/claude-code/issues/50393>,
  <https://github.com/anthropics/claude-code/issues/58588>

So the panel holds the colour itself: `colors.json` next to `server.ps1`, one of
the nine names `/color` uses — `red orange yellow green cyan blue purple pink
default` — per account id. Clicking the dot to the left of an account name
changes it through `POST /api/color?id=&name=`. An unknown name or id is
rejected with a 400.

In `index.html` every name is defined twice — `COLOR_DAY` (darkened, for paper)
and `COLOR_NIGHT` (bright, for the dark panel). The same night coefficient that
drives the rest of the palette rides between them, so any colour you pick lands
inside the range of both themes automatically.

Shortcut → directory mapping comes from `config.json`; on the machine this was
built for it is:

| Shortcut | Config dir | Colour |
|---|---|---|
| Claude Personal 1 | `.claude_personal` | blue |
| Claude Personal 2 | `.claude_personal2` | green |
| Claude Work | `.claude_work` | orange |

## What the Launch button does

`POST /api/launch?id=` starts the account's launcher from `%USERPROFILE%` and
releases the server loop immediately: the waiting is done by a separate
`launch-color.ps1` process. The button can be pressed as many times in a row as
you like — each press gets its own waiter, and `.claims/<pid>.claim` (created
with `CreateNew`, i.e. atomically) keeps two waiters from grabbing the same
window.

The waiter looks for a **process**, not a session: a `claude.exe` whose parent
is this account's launcher and which started after the waiter itself. Looking by
session is impossible — `sessions/<pid>.json` only appears after the folder
trust question is answered, and that question is exactly what the waiter is
waiting on.

The process shows up while its TUI is still being drawn, so a key pressed right
away lands before there is a prompt to take it: the waiter sleeps a second, then
sends `poke.ps1 -Keys "down,enter"` — "Yes, I trust this folder". If the window
already has a `sessions/<pid>.json` it answered that question on an earlier run
and its input line is live, so no keys are sent: Down plus Enter would be typed
into the conversation.

Colour goes on last, and only once the session file exists (up to a minute of
waiting) — that is the same moment the panel starts counting the window as
running. `POST /api/color` carries the `pid`, so exactly this window is painted
rather than every window of the account.

On startup the server strips `CLAUDE*`, `AI_AGENT`, `NO_COLOR` and `FORCE_COLOR`
from its own environment. Otherwise, when the panel is started from inside
Claude Code itself, a new window inherits `CLAUDE_CODE_CHILD_SESSION` (writes no
session — the panel never sees it and never paints it) and `CLAUDE_CONFIG_DIR`
from another account. `NO_COLOR` is in the same set: a Claude Code shell sets it
for its children, and carried this far it reaches the launched window's own TUI,
which then draws monochrome no matter what `/color` says.

## Caveats

`/api/oauth/usage` is an internal Claude Code endpoint, not a public API. It can
change without notice. The request is therefore wrapped: any error quietly drops
the account onto the `.claude.json` cache, the page keeps working, and the
reason is visible at `/api/debug`.

Percentages "age forward": when `resets_at` is already in the past, the window
counts as reset and shows as 0 % labelled `free`. For the live source that
almost never fires; for the cache it fires constantly.

## Running it

```
"Rainbow Claude Monitor.bat"   # start it minimised (the same file fits startup)
```
or by hand:
```
powershell -ExecutionPolicy Bypass -File server.ps1
```
Then <http://127.0.0.1:8777>. The port comes from `config.json` and can be
overridden for one run with `-Port`.

Starting it a second time is harmless: before binding, the server probes the
port, and if the panel already answers there it just opens the browser and
exits. That is what makes the .bat safe to leave in startup and to double-click
afterwards.

## API

- `GET /` — the page
- `GET /api/config` — the `ui` block for the client
- `GET /api/stats` — `{ cpu, ram, host, accounts[] }`, each account carries `source: api|cache`
- `GET /api/debug` — what the live limit poll returned (no tokens)
- `POST /api/refresh` — drop the live cache and re-fetch
- `POST /api/color?id=&name=[&pid=]` — paint an account's windows
- `POST /api/launch?id=` — start the account's launcher

## Possible additions

- GPU through `nvidia-smi`, if it is ever needed
- a sound or notification when a limit crosses 90 %
- refreshing the token with `refresh_token` when the access token expires
  (today it simply falls back to the cache)
