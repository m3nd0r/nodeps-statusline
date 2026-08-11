#!/usr/bin/env bash
# Test suite for statusline.sh.
#
# Written in plain bash on purpose: the script under test clears a "no
# dependencies" bar, and a suite that reached for jq or sed to check it would be
# quietly moving that bar somewhere the script cannot follow.
#
# Times are asserted under TZ=UTC so the expectations hold on any machine, and
# the payloads are the shapes documented at
# https://code.claude.com/docs/en/statusline — including the ones the docs warn
# may be absent or null.
#
#   ./test.sh        run everything
#   ./test.sh -v     also print the rendered line for every case

# C rather than the caller's locale, so `date` names months in English on every
# runner; the assertions compare bytes, which multibyte glyphs survive intact.
export TZ=UTC LC_ALL=C

verbose=""
[ "${1:-}" = "-v" ] && verbose=1

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script=$here/statusline.sh
[ -r "$script" ] || { echo "cannot read $script" >&2; exit 1; }

work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT
cp "$script" "$work/sl.sh"
: > "$work/noise"

# A second copy with the bash 4.2 fast path removed, so the date(1) branch that
# stock macOS /bin/bash would take is exercised on every run rather than trusted.
: > "$work/fb.sh"
while IFS= read -r __line; do
  case $__line in '((BASH_VERSINFO'*) continue ;; esac
  printf '%s\n' "$__line" >> "$work/fb.sh"
done < "$script"

pass=0; fail=0

strip_ansi() {
  local s=$1 out=""
  while [[ $s == *$'\033['* ]]; do
    out+=${s%%$'\033['*}
    s=${s#*$'\033['}
    s=${s#*m}
  done
  printf '%s' "$out$s"
}

# Colours become readable words so an assertion can talk about them.
name_colors() {
  local s=$1
  s=${s//$'\033[32m'/<green>}; s=${s//$'\033[33m'/<yellow>}; s=${s//$'\033[31m'/<red>}
  s=${s//$'\033[2m'/};         s=${s//$'\033[0m'/}
  printf '%s' "$s"
}

# Whatever the last invocation left on stderr, filed under the case that caused
# it and checked once at the very end — see the "stderr" section for why.
note_stderr() { # $1 = label for the case
  local err=""
  IFS= read -r -d '' err < "$work/err"
  [ -n "$err" ] && printf '%s\n%s\n' "$1" "$err" >> "$work/noise"
  return 0
}

# $1 = config JSON ("" writes no config file at all), $2 = payload,
# $3 = which copy to run ("sl" default, "fb" for the date(1) branch).
# Leaves the rendered line in $line and the raw, still-coloured one in $raw.
run() {
  local base=$work/${3:-sl}
  if [ -n "$1" ]; then printf '%s' "$1" > "$base.json"; else rm -f "$base.json"; fi
  raw=$(printf '%s' "$2" | bash "$base.sh" 2> "$work/err")
  line=$(strip_ansi "$raw")
  rm -f "$base.json"
  note_stderr "config ${1:-(none)}"
}

section() { printf '\n  %s\n' "$1"; }

ok()  { pass=$((pass + 1)); printf '    \033[32m✓\033[0m %s\n' "$1"
        [ -n "$verbose" ] && printf '        %s\n' "$line"; return 0; }
bad() { fail=$((fail + 1)); printf '    \033[31m✗\033[0m %s\n' "$1"
        printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; return 0; }

is()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has()   { case $3 in *"$2"*) ok "$1" ;; *) bad "$1" "contains: $2" "$3" ;; esac; }
hasnt() { case $3 in *"$2"*) bad "$1" "must not contain: $2" "$3" ;; *) ok "$1" ;; esac; }

# --- payloads ---------------------------------------------------------------
# The full example from the docs, trimmed of the fields the script never reads
# but keeping every one that sits between it and the fields it does.
DOCS='{"cwd":"/d","session_id":"abc","model":{"id":"claude-opus-5","display_name":"Opus"},
"workspace":{"current_dir":"/d","added_dirs":[],"repo":{"host":"github.com","name":"cc"}},
"version":"2.1.90","output_style":{"name":"default"},
"cost":{"total_cost_usd":0.01234,"total_duration_ms":45000},
"context_window":{"total_input_tokens":15500,"total_output_tokens":1200,"context_window_size":200000,
"used_percentage":8,"remaining_percentage":92,
"current_usage":{"input_tokens":8500,"cache_read_input_tokens":2000}},
"exceeds_200k_tokens":false,"effort":{"level":"high"},
"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600},
"seven_day":{"used_percentage":41.2,"resets_at":1738857600}},
"vim":{"mode":"NORMAL"},"pr":{"number":1234,"url":"https://github.com/a/b/pull/1234"}}'

BIG='{"model":{"display_name":"Opus 5 (1M context)"},
"context_window":{"used_percentage":37,"total_input_tokens":372845,"context_window_size":1000000},
"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1754650800},
"seven_day":{"used_percentage":91,"resets_at":1755000000}}}'

MINIMAL='{"model":{"display_name":"Opus"},"context_window":{"used_percentage":8}}'

printf '\nstatusline.sh\n'

# --- the documented shape ---------------------------------------------------
section "documented payload"

run "" "$DOCS"
is "renders model, context, both windows" \
   'Opus │ 🧠 ▰▱▱▱▱▱▱▱▱▱ 8% 15k/200k │ ⏳ 23% → 16:00 │ 📅 41% → Feb 6' "$line"

run "" "$BIG"
is "strips the model qualifier and abbreviates tokens" \
   'Opus 5 │ 🧠 ▰▰▰▰▱▱▱▱▱▱ 37% 372k/1M │ ⏳ 42% → 11:00 │ 📅 91% → Aug 12' "$line"

run "" '{"model":{"display_name":"Opus"},"context_window":{"current_usage":{"input_tokens":8500},
"total_input_tokens":15500,"context_window_size":200000,"used_percentage":8}}'
has "reads past a nested object that precedes the keys" "8% 15k/200k" "$line"

run "" '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":1738425600}}}'
has "handles a rate_limits with only one window" "⏳ 23% → 16:00" "$line"
hasnt "and shows no 7-day segment for it" "📅" "$line"

# --- degradation ------------------------------------------------------------
# Every one of these must lose a segment rather than print a wrong number.
section "degradation"

run "" ''
is "empty stdin falls back to a bare model name" 'Claude' "$line"

run "" 'this is not json'
is "unparseable stdin does the same" 'Claude' "$line"

run "" '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":null,"current_usage":null}}'
is "a null used_percentage drops the context segment" 'Opus' "$line"

run "" '{"model":{"display_name":"Opus"},"context_window":{"a":{"b":{"c":1}},"used_percentage":8}}'
is "two levels of nesting hide the key, as documented" 'Opus' "$line"

run "" '{"model":{"id":"a{b","display_name":"Opus"}}'
is "a brace inside a string hides the field, never mis-reads it" 'Claude' "$line"

run "" '{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42,
"resets_at":"2026-08-08T12:00:00Z"}}}'
has "a non-numeric resets_at leaves the percentage alone" "⏳ 42%" "$line"
hasnt "and appends no dangling arrow" "→" "$line"

run "" '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":150}}'
has "a percentage above 100 fills the bar without overflowing it" "▰▰▰▰▰▰▰▰▰▰ 150%" "$line"

run "" '{"model":{"display_name":"He said \"hi\" \\ ok"}}'
is "JSON escapes in the display name are unwound" 'He said "hi" \ ok' "$line"

# --- the rate-limit notice --------------------------------------------------
# rate_limits reaches only Claude.ai subscribers, and only after the first API
# response. context_window.used_percentage arrives on that same response, which
# is what tells "too early to know" apart from "will never have them".
section "rate-limit notice"

run "" '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":null}}'
is "a session with no response yet says nothing" 'Opus' "$line"

run "" "$MINIMAL"
has "a session with a response but no windows says so" "(rate limits unavailable)" "$line"

run "" "$DOCS"
hasnt "a subscriber session never sees the notice" "unavailable" "$line"

# --- configuration ----------------------------------------------------------
section "configuration"

run "" "$BIG"; default_line=$line
run '{}' "$BIG"
is "an empty config matches no config at all" "$default_line" "$line"
run '{"time_format":' "$BIG"
is "malformed JSON leaves every default standing" "$default_line" "$line"
run '{"emoji":true,"icon_context":"🧠","icon_session":"⏳","icon_week":"📅","time_format":"24h",
"week_format":"%b %e","bar_width":10,"bar_filled":"▰","bar_empty":"▱","warn_percent":70,
"crit_percent":90,"separator":"│","show_tokens":true}' "$BIG"
is "the example config reproduces the defaults exactly" "$default_line" "$line"

for v in 'false' '"false"' '"False"' '0' '"no"' '"off"'; do
  run "{\"emoji\":$v}" "$BIG"
  hasnt "emoji:$v turns the icons off" "🧠" "$line"
done
run '{"emoji":"maybe"}' "$BIG"
has "an unrecognised emoji value leaves them on" "🧠" "$line"

run '{"bar_width":0}' "$BIG"
has "bar_width 0 drops the bar and keeps the spacing" "🧠 37%" "$line"
run '{"bar_width":20}' "$BIG"
has "bar_width 20 widens it" "▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱" "$line"
run '{"bar_width":999}' "$BIG"
has "an absurd bar_width is clamped, not honoured" "▱ 37%" "$line"
run '{"bar_width":"abc"}' "$BIG"
is "a non-numeric bar_width falls back to the default" "$default_line" "$line"

# A zero-padded number is still a number to anyone writing a config by hand, but
# $(( )) reads it as octal — "09" not as a number at all, which used to abort the
# arithmetic and take the entire context segment down with it.
run '{"bar_width":"09"}' "$BIG"
has "a zero-padded bar_width is decimal, not octal" "▰▰▰▰▱▱▱▱▱ 37%" "$line"
run '{"bar_width":"010"}' "$BIG"
is "and ten padded to three digits is still ten" "$default_line" "$line"
run '{"bar_width":100}' "$BIG"; clamped_line=$line
run '{"bar_width":99999999999999999999}' "$BIG"
is "a width too long to be an integer clamps like any other" "$clamped_line" "$line"

# Not every path holds a file. A directory is readable, so the guard used to let
# the redirect through and mutter at a stream nobody reads.
mkdir -p "$work/sl.json"
raw=$(printf '%s' "$BIG" | bash "$work/sl.sh" 2> "$work/err"); line=$(strip_ansi "$raw")
note_stderr 'config (a directory)'
rmdir "$work/sl.json"
is "a directory where the config goes leaves the defaults" "$default_line" "$line"

run '{"bar_filled":"#","bar_empty":"-"}' "$BIG"
has "the bar glyphs are replaceable with ASCII" "####------ 37%" "$line"
run '{"separator":"·"}' "$BIG"
has "the separator is replaceable" "Opus 5 · 🧠" "$line"
run '{"show_tokens":false}' "$BIG"
hasnt "show_tokens false hides the token tail" "372k/1M" "$line"

run '{}' "$BIG";                             d=$(name_colors "$raw")
has "37/42/91 read green/green/red by default" "<red>91%" "$d"
has "and the low figures stay green"           "<green>▰▰▰▰▱▱▱▱▱▱ 37%" "$d"
run '{"warn_percent":20,"crit_percent":40}' "$BIG"; d=$(name_colors "$raw")
has "lowering the thresholds turns 37% yellow" "<yellow>▰▰▰▰▱▱▱▱▱▱ 37%" "$d"
has "and 42% red"                              "<red>42%" "$d"
run '{"warn_percent":95,"crit_percent":99}' "$BIG"; d=$(name_colors "$raw")
has "raising them turns 91% green"             "<green>91%" "$d"

# --- time formats -----------------------------------------------------------
section "time formats"

run '{"time_format":"12h"}' "$BIG";    has "12h renders a meridiem clock" "→ 11:00 AM" "$line"
run '{"time_format":"24H"}' "$BIG";    has "shorthands ignore case" "→ 11:00" "$line"
run '{"time_format":"24hr"}' "$BIG";   has "24hr is accepted too" "→ 11:00" "$line"
run '{"time_format":"%H.%M"}' "$BIG";  has "anything with a % goes to strftime" "→ 11.00" "$line"
run '{"time_format":"HH:MM"}' "$BIG";  has "a misspelt shorthand falls back to a real clock" "→ 11:00" "$line"
hasnt "rather than printing the typo" "HH:MM" "$line"
run '{"time_format":""}' "$BIG";       hasnt "an empty format hides the reset time" "→ 11" "$line"
has "while leaving the percentage" "⏳ 42%" "$line"

run '{"week_format":"nonsense"}' "$BIG"
has "the same rule covers week_format" "→ Aug 12" "$line"
run '{"week_format":"%b %e (wk %V)"}' "$BIG"
has "a format carrying a paren still renders" "→ Aug 12 (wk 33)" "$line"

# A format may emit a newline at strftime time, long after the config was read.
# A status line is one line; this used to leak a separator and swap two fields.
run '{"time_format":"%H%n%M"}' "$BIG"
hasnt "a newline in the output cannot split the line" $'\n' "$line"
hasnt "nor leak the record separator" $'\037' "$line"
has "and the week segment keeps its own value" "📅 91% → Aug 12" "$line"
run '{"separator":"a\nb"}' "$BIG"
hasnt "a literal newline in a config string is stripped" $'\n' "$line"

# --- the two time backends must agree ---------------------------------------
section "date(1) fallback"

for cfg in '' '{"time_format":"12h"}' '{"week_format":"%Y-%m-%d"}'; do
  run "$cfg" "$BIG";       builtin_line=$line
  run "$cfg" "$BIG" fb;    fallback_line=$line
  is "printf %()T and date agree on ${cfg:-defaults}" "$builtin_line" "$fallback_line"
done

# --- version ----------------------------------------------------------------
# The one invocation that carries no payload. It has to answer before the stdin
# slurp — a regression that moves it after would print a status line here — and
# release.yml parses the same string to check the tag it is building.
section "--version"

line=$(bash "$work/sl.sh" --version < /dev/null 2> "$work/err"); rc=$?
note_stderr '--version'
is "--version exits 0" 0 "$rc"
case $line in
  'nodeps-statusline '[0-9]*.[0-9]*.[0-9]*) ok "prints the name and a semver" ;;
  *) bad "prints the name and a semver" "nodeps-statusline X.Y.Z" "$line" ;;
esac
is "-V is the short form of it" "$line" "$(bash "$work/sl.sh" -V < /dev/null)"

# --- nothing on stderr ------------------------------------------------------
# One check standing behind every case above. Claude Code renders the line from
# stdout, so anything the script mutters beside it is invisible in normal use
# right up until it isn't — and it is exactly what a config the parser
# mishandles produces, while stdout still looks plausible enough to pass.
section "stderr"

noise=""
IFS= read -r -d '' noise < "$work/noise"
is "no case wrote anything to stderr" "" "$noise"

# --- summary ----------------------------------------------------------------
printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n\n' "$pass"
else
  printf '\033[31m%d failed\033[0m, %d passed\n\n' "$fail" "$pass"
fi
[ "$fail" -eq 0 ]
