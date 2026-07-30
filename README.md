# Herdr Touch Bar

Your [herdr](https://herdr.dev) agents on the MacBook Touch Bar. A badge in the
Control Strip tells you how many agents are working or waiting on you; tap it and
the Touch Bar becomes a row of agents you can jump straight into.

![The Control Strip badge, showing two agents at work](docs/control-strip.png)

Tap it and the whole bar becomes your herd:

![The expanded panel: one button per agent, showing its icon, tab name and project](docs/panel.png)

## What you see

**The Control Strip badge** is always there, whatever app you are in:

| Badge | Meaning |
|---|---|
| `⏸ 2` (red) | 2 agents are blocked and waiting for you |
| `⠹ 3` (orange) | 3 agents are working — the braille glyph spins while they do |
| `⏸1 ⠹3` (red) | both, blocked count first |
| `✓ 2` (green) | 2 agents just finished |
| `⠿ 9` (grey) | 9 agents, all idle |
| `⃠ herdr` (grey) | the herdr server is not running |

**The expanded panel** (above) shows one button per agent: its brand icon, its tab name,
its project name in a smaller second line, and a colour for its state — red
blocked, orange working (with a live spinner), green done, grey idle. The agent you
are currently in gets a brighter button. Tapping one focuses that agent in herdr
and brings the terminal to the front.

Agents are ordered the way your sidebar is, by following herdr's own
`ui.agent_panel_sort`:

- `spaces` (herdr's default) lays them out by space, in the arrangement you
  dragged them into. Reordering a tab in herdr moves it here too.
- `priority` puts whoever wants something from you first — blocked, then done,
  then working, then idle — and falls back to the same arrangement within each
  group.

herdr does not document the exact precedence inside its own attention queue, so
`priority` here is a close reading of it rather than a guarantee; if your sidebar
disagrees, `HERDR_TOUCHBAR_SORT` pins the mode regardless of herdr's setting.

The panel stays up after a tap — hopping between agents is the whole point, and
reopening it every time would be worse than leaving it in reach. The ✕ on the left
collapses back to the Control Strip, which you will want when you need the volume
and brightness keys back.

## Install

```sh
herdr plugin install omerturhan/herdr-touchbar
```

Or from a local checkout:

```sh
git clone https://github.com/omerturhan/herdr-touchbar
cd herdr-touchbar
herdr plugin link .
```

Installing runs `build.sh`, which compiles and ad-hoc signs
`build/HerdrTouchBar.app`. It includes both Intel and Apple silicon slices when
the installed toolchain can produce them. No Xcode project and no developer
account are needed — just the command line tools.

That is the whole setup. The plugin's `[[startup]]` hook launches the app once
herdr has restored its session, and herdr itself starts at login, so the badge
comes back on its own after a reboot. To bring it up right now without waiting:

```sh
bash bin/run.sh start
```

There is also a "Touch Bar: start / restart" entry in herdr's plugin action menu.

**No LaunchAgent, on purpose.** An earlier version installed one in
`~/Library/LaunchAgents`, and macOS announced "HerdrTouchBar added items that can
run in the background" at *every* login. Background items are tracked by code
signature, and an ad-hoc signature changes on every rebuild, so the system kept
treating it as something new. Letting herdr own the lifecycle removes the
registration entirely — and herdr is already running whenever this plugin has
anything to show.

## Requirements

- A MacBook Pro with a Touch Bar
- macOS 11 or later (verified on macOS 26.5 / Apple M1)
- herdr 0.7.5+ running, with its socket at `~/.config/herdr/herdr.sock`

## Controlling it

```sh
bash bin/run.sh start|restart|stop|status
bash bin/run.sh open      # expand the agent panel
bash bin/run.sh close     # collapse it
```

`open` and `close` work by signalling the running app (`SIGUSR1` / `SIGUSR2`), so
you can bind them to a herdr keybinding and pop the agent list up from the
keyboard instead of reaching for the Touch Bar.

## Uninstall

```sh
bash bin/run.sh stop
herdr plugin uninstall herdr-touchbar
```

## Configuration

Put these in a `.env` file in the plugin's config directory:

```sh
"$(herdr plugin config-dir herdr-touchbar)"/.env
```

Exporting them in a shell before `bin/run.sh start` does not work: the app is
launched through `open`, and LaunchServices does not pass along the environment
of whatever asked for the launch. The file is read at startup, so restart the app
after editing it. Real environment variables still win when the app does inherit
them.

| Variable | Default | Effect |
|---|---|---|
| `HERDR_TOUCHBAR_ONLY_ACTIVE` | unset | `1` hides idle agents, leaving only the ones working or waiting |
| `HERDR_TOUCHBAR_SORT` | follows herdr | `spaces` or `priority`, to pin the order instead of following `ui.agent_panel_sort` |
| `HERDR_TOUCHBAR_TERMINAL_BUNDLE_ID` | auto-detected | which terminal to raise when you tap an agent. Ghostty, iTerm2, kitty, WezTerm, Alacritty, Warp and Terminal.app are tried in that order; set this if yours is missing or you run several |
| `HERDR_SOCKET_PATH` | `~/.config/herdr/herdr.sock` | herdr control socket |
| `HERDR_TOUCHBAR_DEBUG` | unset | `1` for verbose logging |

See [`.env.example`](.env.example) for a copyable version. The app logs to
`~/Library/Logs/herdr-touchbar.log`.

## How it works

The app is a background (`LSUIElement`) AppKit process. It places an item in the
Control Strip through the private `DFRFoundation` API and `NSTouchBarItem`'s
`addSystemTrayItem:` — the same entry points MTMR and Pock use — and presents the
expanded bar with `presentSystemModalTouchBar:placement:systemTrayItemIdentifier:`.
The Touch Bar service only talks to code running from a real `.app` bundle, which
is why `build.sh` assembles one rather than leaving a bare binary.

State comes from herdr's own socket API: it bootstraps with an atomic
`session.snapshot`, then holds an `events.subscribe` stream open and re-derives
the picture whenever something changes. Bursts of events are coalesced, and the
UI only repaints when the derived state actually differs, so an agent spewing
output does not turn into a busy loop. The spinner timer only runs while
something is working.

The plugin's `[[startup]]` hook launches the app once the herdr session is
restored; the single `[[events]]` hook does not push data — the app has its own
subscription — and relaunches it if it is not running when a new agent is
detected.

## Credits

Agent icons are from [lobe-icons](https://github.com/lobehub/lobe-icons) (MIT) —
see [`assets/icons/NOTICE.md`](assets/icons/NOTICE.md).

The private Touch Bar API surface is documented by
[MTMR](https://github.com/Toxblh/MTMR) and [Pock](https://github.com/pock/pock).
