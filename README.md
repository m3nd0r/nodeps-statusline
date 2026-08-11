# nodeps-statusline

A [Claude Code](https://claude.com/claude-code) status line that shows how much
of your context window and of your Claude.ai subscription you have spent.

One bash script, zero dependencies. No `jq`, no Node, no Python — nothing to
install but the file itself.

![The status line: model, context bar, 5-hour and 7-day usage](docs/img/default.svg)

## What it shows

![Everything at once](docs/img/pressure.svg)

| Segment | What it is |
|---|---|
| `Opus 5` | the model, qualifier stripped |
| `▰▰▰▰▱▱▱▱▱▱ 37%` | context window used |
| `372k/1M` | tokens in context / window size |
| `⏳ 42% → 11:00` | the rolling 5-hour window, and when it resets |
| `📅 91% → Aug 12` | the 7-day window, and when it resets |

The two clock segments are your Claude.ai rate limit windows. Figures turn
yellow at 70% and red at 90%.



Every segment is independent. A field the payload does not carry simply does not
render — the line degrades to whatever it does know rather than disappearing or
printing a wrong number.

## Requirements

| | |
|---|---|
| **bash** | 4.2 or newer for the fast path; 3.2 works and falls back to `date` |
| **Claude Code** | any version that sends `context_window`; `rate_limits` needs v2.x |
| **A Claude.ai subscription** | Pro or Max, for the ⏳ and 📅 segments only |
| **Anything else** | no |

Runs on Linux, macOS and Windows (Git Bash / MSYS2 / Cygwin).

The ⏳ and 📅 segments come from `rate_limits`, which Claude Code sends only to
Claude.ai subscribers and only after the first API response of a session. On an
API key, Bedrock or Vertex the line quietly shows the model and context bar
instead.

## Install

Put the script anywhere; `~/.claude/` keeps it next to the settings that point
at it.

```bash
mkdir -p ~/.claude
curl -fsSL https://raw.githubusercontent.com/m3nd0r/nodeps-statusline/main/statusline.sh \
  -o ~/.claude/statusline.sh
```

That path follows `main`, so a later fix reaches you the next time you fetch it.
Put a tag there instead — `…/v1.0.0/statusline.sh` — and the file stops moving
under you; every [release](https://github.com/m3nd0r/nodeps-statusline/releases)
carries the same script with its `sha256` beside it.

Or clone it and copy the one file you need:

```bash
git clone https://github.com/m3nd0r/nodeps-statusline.git
cp nodeps-statusline/statusline.sh ~/.claude/statusline.sh
```

## Connect it

Add a `statusLine` block to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "padding": 0
  }
}
```

`padding: 0` lets the line start at the left edge. Restart Claude Code, or run
`/config`, and the line appears at the bottom.

To check it without Claude Code, feed it a payload by hand:

```bash
echo '{"model":{"display_name":"Opus 5"},"context_window":{"used_percentage":37}}' \
  | bash ~/.claude/statusline.sh
```

`bash ~/.claude/statusline.sh --version` says which copy you ended up with.

## Configure

Everything works with no configuration. To change something, drop a
`statusline.json` **beside the script** — same directory, same name, `.json`
instead of `.sh`:

```bash
cp statusline.example.json ~/.claude/statusline.json
```

Every key is optional; delete the ones you are not changing. A missing file, a
missing key and a malformed file all mean the same thing — the default stands.

| Key | Default | What it does |
|---|---|---|
| `emoji` | `true` | `false`, `no`, `off` or `0` strips all three icons at once |
| `icon_context` | `🧠` | Prefix for the context segment. Any string — `"ctx"` works |
| `icon_session` | `⏳` | Prefix for the 5-hour segment |
| `icon_week` | `📅` | Prefix for the 7-day segment |
| `time_format` | `24h` | `24h`, `12h`, or any strftime string. `""` hides the reset time |
| `week_format` | `%b %e` | strftime for the 7-day reset date. `""` hides it |
| `bar_width` | `10` | Cells in the context bar. `0` removes the bar, keeping the percentage |
| `bar_filled` | `▰` | Glyph for a used cell — `"#"` for a terminal with no box drawing |
| `bar_empty` | `▱` | Glyph for a free cell |
| `warn_percent` | `70` | At or above this, figures turn yellow |
| `crit_percent` | `90` | At or above this, figures turn red |
| `separator` | `│` | Drawn dim between segments |
| `show_tokens` | `true` | `false` hides the `372k/1M` tail |

Shorthands are matched case-insensitively, and a value that looks like neither a
shorthand nor a format falls back to the default rather than being printed where
a clock belongs.

### Gallery

Every image below is the actual output of the script under the config shown,
captured with its colours — none of them is a drawing.

**ASCII only**, for terminals without emoji or box-drawing glyphs:

```json
{ "emoji": false, "bar_filled": "#", "bar_empty": "-", "separator": "|" }
```

![](docs/img/ascii.svg)

**Wider bar, 12-hour clock, weekday in the date:**

```json
{ "bar_width": 20, "time_format": "12h", "week_format": "%a %d %b" }
```

![](docs/img/wide.svg)

**Stripped down** — no bar, no token counts, no 7-day date:

```json
{ "bar_width": 0, "show_tokens": false, "separator": "·", "week_format": "" }
```

![](docs/img/minimal.svg)

**Solid blocks and tighter thresholds:**

```json
{ "bar_filled": "█", "bar_empty": "░", "bar_width": 14,
  "warn_percent": 30, "crit_percent": 60 }
```

![](docs/img/blocks.svg)

## How it works

Claude Code hands the script a JSON object on stdin
([schema](https://code.claude.com/docs/en/statusline)) and prints whatever comes
back. The interesting part is what the script refuses to do.

**It does not shell out to parse JSON.** Every field it needs sits one level
deep inside a named object, so one regex per field is enough, and bash has a
regex engine built in. There is no dependency to install and no process to
fork for it.

**It does not fork at all, if it can help it.** Helpers return through a global
`$_out` rather than `$( )`, because a command substitution forks a subshell —
measured at ~6 ms under Cygwin, and there are around nineteen helper calls per
redraw. Timestamps are formatted with bash's own `printf '%(…)T'` on 4.2+, which
replaced a `date` call that was costing 35 ms of a 63 ms line:

| | per redraw |
|---|---|
| bash startup alone, doing nothing | 23 ms |
| this script | **28 ms** |
| the same script when it called `date` | 63 ms |

Older shells — stock macOS `/bin/bash` is still 3.2 — fall back to `date`, BSD
flavour first, then GNU. Both paths are asserted to produce identical output.

**It has no `set -e`, on purpose.** A status line that vanishes tells you less
than one missing a segment. Every field is independently optional, and a field
that cannot be read is treated exactly like a field that was null: its segment
disappears. Nothing in the script prints a number it is not sure of.

## Known limits

- **The parser spans one level of nesting and does not understand strings.** A
  brace inside a string value, or a second level of nesting between the parent
  object and the key, hides the keys after it. Neither occurs in today's
  payload, and both fail the way a null does — the segment disappears rather
  than showing something wrong. `INNER_KEYS` in the script is where to look if a
  segment goes missing after a schema change.
- **The config must sit next to the script.** It is found as
  `${BASH_SOURCE[0]%.sh}.json`, so moving the script without moving the config
  silently reverts you to the defaults.
- **Percentages are truncated, not rounded** — 23.9% reads as 23% — while the
  bar rounds up, so any non-zero percentage lights at least one cell.
- **Token counts are truncated to whole units**, so 999,999 reads as `999k` and
  1,000,000 as `1M`, with nothing in between.

## Tests

```bash
./test.sh        # 64 checks
./test.sh -v     # and print every rendered line
```

Plain bash, no test framework — the script under test clears a "no
dependencies" bar and the suite that checks it should clear the same one. It
asserts against the payload shapes from the official docs, including the ones
the docs warn may be absent or null, and it runs the `date` fallback path on
every machine by stripping the bash 4.2 check out of a scratch copy.

## License

[MIT](LICENSE)
