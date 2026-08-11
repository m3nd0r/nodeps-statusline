#!/usr/bin/env bash
# Claude Code status line: official subscription usage (5-hour + 7-day windows).
# Reads JSON from stdin (see https://code.claude.com/docs/en/statusline).
#
# Portable across Windows (Git Bash / MSYS2), Linux and macOS:
#   * JSON is parsed with bash's own regex engine — jq is not required;
#   * reset timestamps are formatted by bash itself on 4.2+, and only fall back
#     to an external `date` on older shells (macOS's stock /bin/bash 3.2).
#
# Two things below look like omissions but are deliberate:
#   * there is no `set -e` — a status line should degrade to a partial line
#     rather than vanish, so every field is independently optional;
#   * helpers return through the global $_out instead of $(...) — command
#     substitution forks a subshell, measured at ~6 ms under Cygwin, and there
#     are ~19 helper calls per redraw.

STATUSLINE_VERSION=1.0.0 # release.yml asserts this equals the tag being built

# Answered before the slurp below, which waits for EOF and so would hang on a
# terminal: this is the one invocation that arrives without a payload.
case "${1:-}" in
  -V|--version) echo "nodeps-statusline $STATUSLINE_VERSION"; exit 0 ;;
esac

IFS= read -r -d '' status_input # slurp stdin without forking `cat`;
                                # the nonzero return at EOF is expected

# --- field extraction -------------------------------------------------------
# Every field we need lives one level deep inside a named object, so a single
# regex per field is enough. A missing field just leaves $_out empty.
#
# INNER_KEYS skips over the keys preceding the one we want: it consumes
# brace-free runs plus whole nested objects (context_window.current_usage, say),
# so the parent's closing "}" stops the search before it reaches a sibling.
# POSIX ERE has no non-capturing groups, so it costs one capture group of its
# own — the value we actually want always lands in BASH_REMATCH[2].
#
# It counts braces without understanding strings, and spans one level of nesting
# rather than arbitrary depth — so a brace inside a string value, or a second
# level of nesting, hides the keys after it. Neither occurs in today's payload,
# and both fail the way a null does: the field reads as absent and its segment
# disappears, rather than showing a wrong number. Start here if a segment ever
# goes missing after a schema change.
INNER_KEYS='([^{}]*\{[^{}]*\})*[^{}]*'

json_string_field() { # $1 = parent object key, $2 = string key inside it
  _out=""
  # The value pattern walks over JSON escapes ( \" \\ \/ … ) instead of stopping
  # at the first quote, so a quote inside the string cannot truncate the value.
  local __pattern="\"$1\"[[:space:]]*:[[:space:]]*\{$INNER_KEYS\"$2\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]*(\\\\.[^\"\\\\]*)*)\""
  [[ $status_input =~ $__pattern ]] || return 0
  _out=${BASH_REMATCH[2]}
  # Only the escapes a display name can realistically carry — \n, \t and \uXXXX
  # would survive as literals. The order is safe: escapes always come in pairs
  # and ${//} scans left to right, so the "\" of a "\\" is never re-read as the
  # start of the next escape.
  _out=${_out//\\\"/\"}
  _out=${_out//\\\//\/}
  _out=${_out//\\\\/\\}
}

json_number_field() { # $1 = parent object key, $2 = numeric key inside it
  _out=""
  local __pattern="\"$1\"[[:space:]]*:[[:space:]]*\{$INNER_KEYS\"$2\"[[:space:]]*:[[:space:]]*([0-9]+(\.[0-9]+)?)"
  [[ $status_input =~ $__pattern ]] || return 0
  # Truncated once, here: JSON may send 42.7, and every consumer downstream is
  # integer-only arithmetic that would abort on a decimal point.
  _out=${BASH_REMATCH[2]%.*}
}

json_string_field model display_name; model_name=$_out
model_name=${model_name%% (*} # drop the qualifier: "Opus 5 (1M context)" -> "Opus 5"
model_name=${model_name:-Claude}

json_number_field context_window used_percentage;     context_percent=$_out
json_number_field context_window total_input_tokens;  context_used_tokens=$_out
json_number_field context_window context_window_size; context_window_size=$_out

json_number_field five_hour used_percentage; session_percent=$_out
json_number_field five_hour resets_at;       session_reset=$_out
json_number_field seven_day used_percentage; week_percent=$_out
json_number_field seven_day resets_at;       week_reset=$_out

# --- configuration ----------------------------------------------------------
# Optional statusline.json beside this script. Every key may be omitted, and an
# absent — or malformed — file just leaves the defaults standing, since a lookup
# that fails to match is indistinguishable from a key that was never there.
# The schema is flat on purpose: these keys sit at the top level, so the lookups
# below need no brace-walking and none of the INNER_KEYS caveats apply.
#
# The keys and their defaults are listed once, in README.md — and mirrored in
# statusline.example.json, which is a copy-and-edit starting point. The calls
# below are the authority on both: each one names its key and its default.
config_input=""
config_file="${BASH_SOURCE[0]%.sh}.json"
[ -r "$config_file" ] && IFS= read -r -d '' config_input < "$config_file"

config_text() { # $1 = key, $2 = default
  _out=$2
  local __pattern="\"$1\"[[:space:]]*:[[:space:]]*\"([^\"\\\\]*(\\\\.[^\"\\\\]*)*)\""
  [[ $config_input =~ $__pattern ]] || return 0
  _out=${BASH_REMATCH[1]}
  _out=${_out//\\\"/\"}; _out=${_out//\\\\/\\}
  # A status line is a single line. Newlines and the separator this script once
  # used are stripped here rather than at every use site — all three are below
  # 0x80, so no UTF-8 continuation byte can be mistaken for one.
  _out=${_out//$'\n'/}; _out=${_out//$'\r'/}; _out=${_out//$'\037'/}
}

config_number() { # $1 = key, $2 = default, $3 = max (clamped, never rejected)
  _out=$2
  local __pattern="\"$1\"[[:space:]]*:[[:space:]]*\"?([0-9]+)"
  [[ $config_input =~ $__pattern ]] || return 0
  _out=${BASH_REMATCH[1]}
  [ "$_out" -gt "$3" ] && _out=$3
  return 0
}

# Sets $_out to 1 for true and "" for false. Anything unrecognised leaves the
# default standing: a typo should not silently turn a feature off, which is
# exactly what a bare `== false` test used to do to "false" and 0.
config_bool() { # $1 = key, $2 = default (1 or "")
  _out=$2
  local __pattern="\"$1\"[[:space:]]*:[[:space:]]*\"?([A-Za-z01]+)\"?"
  [[ $config_input =~ $__pattern ]] || return 0
  local __value=${BASH_REMATCH[1]}
  shopt -s nocasematch
  case $__value in
    false|no|off|0) _out="" ;;
    true|yes|on|1)  _out=1  ;;
  esac
  shopt -u nocasematch
}

# The icons are plain prefix strings, not necessarily emoji — set one to "5h" or
# "ctx" for a text label.
config_text icon_context "🧠"; icon_context=$_out
config_text icon_session "⏳"; icon_session=$_out
config_text icon_week    "📅"; icon_week=$_out
config_bool emoji 1
[ -n "$_out" ] || { icon_context=""; icon_session=""; icon_week=""; }

config_number bar_width 10 100; bar_width=$_out
config_text bar_filled "▰"; bar_filled=$_out
config_text bar_empty  "▱"; bar_empty=$_out
config_number warn_percent 70 100; warn_percent=$_out
config_number crit_percent 90 100; crit_percent=$_out
config_text separator "│"; separator=$_out
config_bool show_tokens 1; show_tokens=$_out

# "24h" and "12h" are shorthands, matched case-insensitively; anything holding a
# "%" is handed to strftime verbatim, which is how week_format is always
# treated. A non-empty value with no "%" is a misspelt shorthand rather than a
# format — printing it where a clock belongs would be confident nonsense, so it
# falls back to the default. An empty value means "hide this field".
resolve_format() { # $1 = configured value, $2 = default strftime string
  _out=$1
  [ -n "$_out" ] || return 0
  case $_out in *%*) return 0 ;; esac
  shopt -s nocasematch
  case $_out in
    24h|24hr|24) _out='%H:%M'    ;;
    12h|12hr|12) _out='%I:%M %p' ;;
    *)           _out=$2         ;;
  esac
  shopt -u nocasematch
}

config_text time_format 24h; resolve_format "$_out" '%H:%M'; time_format=$_out
config_text week_format '%b %e'; resolve_format "$_out" '%b %e'; week_format=$_out

# --- helpers ----------------------------------------------------------------
# ANSI colors, as real escape characters ($'…') rather than the literal text
# "\033[…". The line is printed with %s, so nothing in the payload — a model name
# containing a backslash, say — is ever taken for an escape sequence.
DIM=$'\033[2m'; RESET=$'\033[0m'
green=$'\033[32m'; yellow=$'\033[33m'; red=$'\033[31m'

# color by usage level
color_for() {
  local __percent=${1:-0}
  if   [ "$__percent" -ge "$crit_percent" ]; then _out=$red
  elif [ "$__percent" -ge "$warn_percent" ]; then _out=$yellow
  else _out=$green; fi
}

# Mini bar, bar_width cells wide. Rounds up, so any non-zero percentage lights a
# cell and the compression lands at the top instead (91-100% all read as full).
# Cells are appended in a loop rather than sliced off a preset string because
# ${var:0:n} counts bytes, not characters, outside a UTF-8 locale.
bar() {
  local __percent=${1:-0} __filled __i
  _out=""
  [ "$bar_width" -gt 0 ] || return 0
  [ "$__percent" -gt 100 ] && __percent=100
  __filled=$(( (__percent * bar_width + 99) / 100 ))
  for ((__i = 0; __i < bar_width; __i++)); do
    if [ "$__i" -lt "$__filled" ]; then _out+=$bar_filled; else _out+=$bar_empty; fi
  done
}

# 15500 -> 15k, 1000000 -> 1M (integer math only, no external tools)
format_token_count() {
  local __count=${1:-0}
  if   [ "$__count" -ge 1000000 ]; then printf -v _out '%dM' $(( __count / 1000000 ))
  elif [ "$__count" -ge 1000 ];    then printf -v _out '%dk' $(( __count / 1000 ))
  else _out=$__count; fi
}

# bash 4.2+ formats epoch seconds with a builtin, which costs nothing measurable
# — the `date` it replaces was over half this script's total runtime. Older
# shells (macOS ships /bin/bash 3.2) still shell out: BSD's -r first, since GNU
# rejects a bare number there, while BSD's -d means something else entirely and
# could answer with the current time instead of failing.
HAVE_PRINTF_TIME=""
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2))) && HAVE_PRINTF_TIME=1

fmt_epoch() { # $1 = epoch seconds, $2 = strftime format
  _out=""
  [ -n "$1" ] && [ -n "$2" ] || return 0
  # printf scans to the first ")" to close %(…)T, so a format carrying one of
  # its own has to take the external route.
  if [ -n "$HAVE_PRINTF_TIME" ] && [[ $2 != *')'* ]]; then
    # shellcheck disable=SC2059  # the format is the point: $2 is a strftime string
    printf -v _out "%($2)T" "$1"
  else
    _out=$(date -r "$1" "+$2" 2>/dev/null || date -d "@$1" "+$2" 2>/dev/null)
  fi
  # A format may still emit a newline (%n) at strftime time, well past the point
  # config_text could have caught it — and a two-line status line is not what
  # anyone configuring a date format asked for.
  _out=${_out//$'\n'/}; _out=${_out//$'\r'/}
  # %e and %l pad single digits with a space, so tidy both ends for any format
  _out=${_out//  / }; _out=${_out# }
}

fmt_epoch "$session_reset" "$time_format"; session_time=$_out
fmt_epoch "$week_reset"    "$week_format"; week_day=$_out

# --- build line -------------------------------------------------------------
status_line=""

# Segments are separated by a dim pipe, but only between them — so whichever
# segment happens to come first never gets a leading separator.
append_segment() {
  [ -n "$status_line" ] && status_line+="${separator:+ ${DIM}${separator}${RESET}} "
  status_line+="$1"
}

append_segment "${DIM}${model_name}${RESET}"

# Only the context window gets a bar — it is the one number worth reading at a
# glance. The subscription windows carry a percentage and their reset moment.
if [ -n "$context_percent" ]; then
  color_for "$context_percent"; usage_color=$_out
  bar "$context_percent"; context_bar=$_out
  context_segment="${icon_context:+$icon_context }${usage_color}${context_bar:+$context_bar }${context_percent}%${RESET}"
  if [ -n "$show_tokens" ] && [ -n "$context_used_tokens" ] && [ -n "$context_window_size" ]; then
    format_token_count "$context_used_tokens";  context_used=$_out
    format_token_count "$context_window_size"; context_total=$_out
    context_segment+=" ${DIM}${context_used}/${context_total}${RESET}"
  fi
  append_segment "$context_segment"
fi

# The reset moment is appended only when it actually parsed, so a `date` that
# understood neither flavour leaves a bare percentage instead of a dangling "→".
if [ -n "$session_percent" ]; then
  color_for "$session_percent"
  append_segment "${icon_session:+$icon_session }${_out}${session_percent}%${RESET}${session_time:+ ${DIM}→ ${session_time}${RESET}}"
fi

if [ -n "$week_percent" ]; then
  color_for "$week_percent"
  append_segment "${icon_week:+$icon_week }${_out}${week_percent}%${RESET}${week_day:+ ${DIM}→ ${week_day}${RESET}}"
fi

# rate_limits reaches only Claude.ai subscribers, and only once an API response
# has landed. context_window.used_percentage arrives on that same response, so
# it tells the two absences apart: no percentage yet means the session is simply
# young and there is nothing to report, while a percentage without any window
# means this session will never have them (API key, Bedrock, Vertex) and the
# notice is the honest answer rather than startup noise.
if [ -z "$session_percent" ] && [ -z "$week_percent" ] && [ -n "$context_percent" ]; then
  append_segment "${DIM}(rate limits unavailable)${RESET}"
fi

printf '%s' "$status_line"
