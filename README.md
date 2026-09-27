# Agents

A bar widget for Omarchy Quattro that shows usage and limits for the coding
agents on this machine, and can launch the one you have selected.

This is a fork of the built-in `omarchy.agents` panel. It adds Grok, Grok Bot,
and Hermes collectors, a right-click launch for the selected agent, and a
Hermes tab that works as a small control center:

- **Recent sessions**: the last six top-level sessions with title, age,
  message count and model. Click one (or press `1`–`6`) to pick it back up:
  desktop sessions reopen in the Hermes app (`hermes://open/<id>`), CLI
  sessions resume in a terminal (`hermes --resume <id>`)
- **Open app** button (right-click the bar icon for a new Hermes chat)
- **Pause / Resume**: Hermes' own emergency stop (`hermes pause`). It holds
  cron, kanban and new gateway turns; work already running keeps going
- Gateway state, active agents, running delegated workers, cron jobs (next
  run, failing count), and estimated session cost today and this week
- Why and when the last session ended (Hermes' own `end_reason`, such as
  `tui close` or `ws disconnect`)

Forked from Omarchy's agents plugin (MIT). Cross-device snapshot sync from
the stock widget is not included.

## Install

```sh
omarchy plugin add https://github.com/Auxxed/omarchy-agents.git --enable
```

The widget lands on the right of the bar. Move it with:

```sh
omarchy bar move io.github.auxxed.agents --section right
```

If the built-in Agents widget is still enabled, disable it so you do not get
two icons:

```sh
omarchy plugin disable omarchy.agents
```

### What you need

The panel is display-only plus launch. Collectors need the matching CLI (or
desktop app) already installed and signed in. Omarchy already ships
`omarchy-agent-usage-update` for Claude, Codex, and Fireworks.

| Tab | Needs |
|---|---|
| Claude | `claude` signed in (`claude auth login`) |
| Grok | `grok` signed in (`grok login`) |
| Grok Bot | Grok Bot desktop signed in, or Cursor CLI auth |
| Hermes | `hermes` with Nous Portal login (`hermes model`) |
| Codex | Codex CLI sessions |
| Fireworks | Fireworks API key / `firectl` |

No extra packages, no root, no user systemd unit. The widget refreshes on
its own timer (default 15 minutes).

## Usage

- **Left-click** the bar icon: open or close the panel
- **Middle-click**: next subscription
- **Right-click**: launch the selected agent in a terminal (Grok Bot focuses
  the desktop app). Agents start without auto-approve / `--yolo` flags
- Hover the bar icon: the fullest limit (or balance) of every agent
- In the panel: `h`/`l` switch subscription, `j`/`k` scroll, `r` or Enter
  refresh, Tab to the next bar panel, Esc closes
- On the Hermes tab: `o` open the app, `1`–`6` resume a session

IPC (parameterless):

```sh
omarchy-shell io.github.auxxed.agents toggle
```

## Configure

```sh
omarchy bar set io.github.auxxed.agents refreshIntervalSec 300 --json
```

Open on a given tab (and make right-click launch that agent) until you pick
another one:

```sh
omarchy bar set io.github.auxxed.agents defaultProvider hermes
```

Show the fullest limit next to the bar icon. It uses the selected agent, or
the fullest window of any agent when the selected one has none:

```sh
omarchy bar set io.github.auxxed.agents barShowPercent On
```

Disable a tab by writing the whole `providers` object:

```sh
omarchy bar set io.github.auxxed.agents providers '{
  "claude": { "enabled": true },
  "grok": { "enabled": true },
  "grok-bot": { "enabled": true },
  "hermes": { "enabled": true },
  "codex": { "enabled": false },
  "fireworks": { "enabled": false }
}' --json
```

## Network

Collectors only talk to these HTTPS hosts, with the already-signed-in token
in an HTTP header (never in argv). Redirects off that host are refused.

| Collector | Endpoint | Credential |
|---|---|---|
| Claude (packaged) | `https://api.anthropic.com/api/oauth/usage` | Claude CLI OAuth |
| Grok | `https://cli-chat-proxy.grok.com/v1/billing?format=credits` and `/v1/user?include=subscription` | `~/.grok/auth.json` OIDC token |
| Grok Bot | `https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus` | Grok Bot `sand-secrets.json` or `~/.cursor/auth.json` |
| Hermes | `https://portal.nousresearch.com/api/oauth/account` | `~/.hermes/auth.json` Nous token |
| Fireworks (packaged) | Fireworks billing API | `FIREWORKS_API_KEY` / `firectl` |

Local stats do not go to the network: Grok sessions under `~/.grok`, Hermes
`~/.hermes/state.db`, Claude/Codex transcripts as the packaged collectors
already do.

The Hermes collector also reads, without writing, `~/.hermes/gateway_state.json`
(the gateway counts as running only if its recorded pid is alive with the
same start time), `~/.hermes/cron/jobs.json`, and whether `~/.hermes/ESTOP`
exists. Session titles are stored in `hermes.json` (see below).

## Commands this plugin runs

Only on a click or key press in the panel, as argv arrays through
`bin/launch-agent`:

| Action | Command |
|---|---|
| Resume desktop session | `uwsm-app -- hermes-desktop hermes://open/<id>` |
| Resume CLI session | `hermes --resume <id>` in `omarchy-launch-tui` |
| Pause / Resume | `hermes pause --reason "Paused from the Omarchy bar"` / `hermes resume` |

Session ids are checked against `^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$` in the
collector, the usage bridge, the panel and the launcher. `hermes` is taken
from `~/.local/bin/hermes` or `/usr/bin/hermes`, not from `PATH`.

## Files this plugin writes

Created on refresh, mode 0600, inside `~/.local/state/omarchy/agents/usage/`:

- `grok.json`
- `grok-bot.json` (removed when Grok Bot is not signed in)
- `hermes.json` (includes the titles of your six most recent Hermes sessions)

Claude, Codex, and Fireworks records in that same directory are written by
Omarchy's packaged `omarchy-agent-usage-update`, not by this plugin.

Collector caches (limits probes, Grok session scans) live under
`~/.cache/omarchy/agent-usage/`.

The plugin does not write credentials, systemd units, sudoers, udev rules,
or shell/Hyprland config.

## Remove

```sh
omarchy plugin remove io.github.auxxed.agents
```

That deletes the plugin directory. It does **not** delete:

- `~/.local/state/omarchy/agents/usage/*.json`
- `~/.cache/omarchy/agent-usage/`
- CLI logins (`~/.grok/auth.json`, `~/.hermes/auth.json`, Claude/Codex/Cursor
  credentials, Grok Bot sand-secrets)

To restore the built-in Agents widget after removal:

```sh
omarchy plugin enable omarchy.agents
```

## License

MIT. Includes code from Omarchy's agents plugin (Copyright David Heinemeier
Hansson) and collectors added in this fork (Copyright 2026 auxxed).
