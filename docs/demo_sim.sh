#!/bin/bash
# Animated re-enactment of the Ezmoji flow, recorded by demo.tape → demo.gif.
# The real picker is a native macOS popup that a terminal recording can't
# capture, so this simulates the same interaction: filter → Tab → swap.

E=$'\033'
DIM="${E}[90m"
SEL="${E}[7m"
RST="${E}[0m"
CYAN="${E}[36m"
INDENT=40

typechars() {
    local s=$1 delay=${2:-0.055} i
    for ((i = 0; i < ${#s}; i++)); do
        printf '%s' "${s:$i:1}"
        sleep "$delay"
    done
}

picker() { # picker <selected-index> <rows...>
    local sel=$1 i=0 out=""
    shift
    out+="${E}7"
    for row in "$@"; do
        out+=$'\n'"${E}[2K"
        if [ "$i" -eq "$sel" ]; then
            out+=$(printf '%*s%s %s %s' "$INDENT" '' "$SEL" "$row" "$RST")
        else
            out+=$(printf '%*s  %s' "$INDENT" '' "$row")
        fi
        i=$((i + 1))
    done
    out+=$'\n'"${E}[2K"$(printf '%*s%s⇥ insert · esc dismiss%s' "$INDENT" '' "$DIM" "$RST")
    out+="${E}8"
    printf '%s' "$out"
}

clear_picker() {
    local out="${E}7" i
    for ((i = 0; i < 5; i++)); do
        out+=$'\n'"${E}[2K"
    done
    out+="${E}8"
    printf '%s' "$out"
}

erase() { # erase <n single-width chars>
    local i
    for ((i = 0; i < $1; i++)); do
        printf '\b \b'
        sleep 0.02
    done
}

clear
sleep 0.4

# ── Scene 1: filter with the picker, Tab to insert ─────────────────────────
printf '%s❯%s ' "$CYAN" "$RST"
typechars 'git commit -m "ship the new dashboard '
typechars ':t' 0.09
picker 0 '🦖 :t-rex:' '🌮 :taco:' '🎉 :tada:'
sleep 0.9
typechars 'a' 0.05
picker 0 '🌮 :taco:' '🎉 :tada:' '🎋 :tanabata_tree:'
sleep 0.8
typechars 'd' 0.05
picker 0 '🎉 :tada:'
sleep 1.1
# ⇥ pressed: Ezmoji erases ":tad" and types the emoji
erase 4
printf '🎉'
clear_picker
sleep 0.15
typechars '"'
sleep 1.0
printf '\n\n\n'

# ── Scene 2: the full :name: form inserts instantly, no Tab needed ─────────
printf '%s❯%s ' "$CYAN" "$RST"
typechars 'echo "the full form is instant :fire' 0.05
typechars ':' 0.05
sleep 0.25
erase 6
printf '🔥'
sleep 0.15
typechars '"'
sleep 1.2
printf '\n\n'
printf '%s# works in every app · github.com/lukebward/Ezmoji%s\n' "$DIM" "$RST"
sleep 4
