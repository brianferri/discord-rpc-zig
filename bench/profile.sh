#!/usr/bin/env bash

# The command functions are reached through the dynamic dispatch in parse_arguments
# shellcheck disable=SC2317
# shellcheck disable=SC2329

SCRIPT="Profile"
VERSION="1.0.0"
AUTHOR="Brian Ferri (https://github.com/brianferri)"

BENCH="zig-out/bin/bench"
ROUNDS=20000
BASELINE="none"

ARGUMENTS=("$@")

ok() { # Print a green [OK]
    local message="$1"
    echo -e "\033[1;32m[OK]\033[0m $message"
}

info() { # Print a cyan [INFO]
    local message="$1"
    echo -e "\033[1;36m[INFO]\033[0m $message"
}

warn() { # Print a yellow [WARN]
    local message="$1"
    echo -e "\033[1;33m[WARN]\033[0m $message"
}

error() { # Print a red [ERROR]
    local message="$1"
    local critical="${2:-}"
    local error_code="${3:-}"
    echo -e "\033[1;31m[ERROR]\033[0m $message"
    if [[ "$critical" == "true" ]]; then
        if [[ -z "$error_code" ]]; then
            exit 1
        else
            exit "$error_code"
        fi
    fi
}

version() {
    echo -e "\033[3m$SCRIPT v$VERSION - $AUTHOR\033[23m"
    exit 0
}

help() {
    echo -e "\033[93;4mUsage:\033[0m"
    echo -e "\t\033[3m$0 <command> [case]\033[23m"

    echo -e "\033[93;4mCommands:\033[0m"
    echo -e "  table    \tInstructions per round and cache misses per million data references"
    echo -e "  detail    \tCachegrind's own report for one case"
    echo -e "  hot    \tThe functions one case spends its instructions in"
    echo -e "  list    \tName every case"
    echo -e "  help    \tView this help"
    echo -e "  version    \tView the version"

    echo -e "\033[93;4mExamples:\033[0m"
    echo -e "  \033[3m$0 table\033[23m"
    echo -e "  \033[3m$0 detail parse_ready\033[23m"
    echo -e "  \033[3m$0 hot serialize_full\033[23m"

    echo ""
    version
}

verify_setup() {
    if ! command -v valgrind >/dev/null 2>&1; then
        error "valgrind is not installed. Please install it before proceeding." true 126
    fi

    if [ ! -x "$BENCH" ]; then
        error "No $BENCH found. Build it with 'zig build bench'." true 126
    fi

    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT
}

cases() { # Every case name, one per line
    "$BENCH" list | awk '{print $1}'
}

case_bytes() { # The bytes one case works over
    local name="$1"
    "$BENCH" list | awk -v want="$name" '$1 == want {print $2}'
}

verify_case() {
    local name="$1"
    if [[ -z "$name" ]]; then
        error "No case given. Run '$0 list' to name one." true 3
    fi
    if ! cases | grep -qx "$name"; then
        error "Unknown case '$name'. Run '$0 list' to name one." true 3
    fi
}

measure() { # Instructions, data references, D1 misses and LL misses for one case
    local name="$1"
    local report="$WORK/$name.report"

    valgrind --tool=cachegrind --cache-sim=yes \
        --cachegrind-out-file="$WORK/$name.cachegrind" \
        "$BENCH" "$name" >/dev/null 2>"$report"

    local instructions refs d1 ll
    instructions=$(field "$report" "I refs:")
    refs=$(field "$report" "D refs:")
    d1=$(field "$report" "D1  misses:")
    ll=$(field "$report" "LL misses:")
    echo "$instructions $refs $d1 $ll"
}

field() { # The first number on the line a label names
    local report="$1"
    local label="$2"
    grep -- "$label" "$report" | head -1 | tr -d ' ,' | sed "s/.*$(echo "$label" | tr -d ' ,')//" |
        grep -o '^[0-9]*'
}

list() {
    "$BENCH" list | while read -r name bytes; do
        printf "  %-24s %s bytes\n" "$name" "$bytes"
    done
}

table() {
    info "Measuring $(cases | wc -l) cases over $ROUNDS rounds, minus the '$BASELINE' baseline"

    local base_instructions base_refs base_d1 base_ll
    read -r base_instructions base_refs base_d1 base_ll <<<"$(measure "$BASELINE")"

    # Misses are given against the data references that could have missed, since a count
    # alone says nothing about whether a working set outgrew the cache.
    printf "\n%-24s %12s %11s %10s %10s\n" CASE INSTR/ROUND INSTR/BYTE D1/MREF LL/MREF
    for name in $(cases); do
        [[ "$name" == "$BASELINE" ]] && continue

        local instructions refs d1 ll bytes per_round per_byte refs_own d1_rate ll_rate
        read -r instructions refs d1 ll <<<"$(measure "$name")"
        bytes=$(case_bytes "$name")

        per_round=$(((instructions - base_instructions) / ROUNDS))
        per_byte=0
        [[ "$bytes" -gt 0 ]] && per_byte=$((per_round / bytes))

        refs_own=$((refs - base_refs))
        d1_rate=0
        ll_rate=0
        if [[ "$refs_own" -gt 0 ]]; then
            d1_rate=$(((d1 - base_d1) * 1000000 / refs_own))
            ll_rate=$(((ll - base_ll) * 1000000 / refs_own))
        fi

        printf "%-24s %12d %11d %10d %10d\n" \
            "$name" "$per_round" "$per_byte" "$d1_rate" "$ll_rate"
    done

    echo ""
    ok "Done"
}

detail() {
    local name="${ARGUMENTS[1]:-}"
    verify_case "$name"

    info "Cachegrind over '$name'"
    valgrind --tool=cachegrind --cache-sim=yes \
        --cachegrind-out-file="$WORK/$name.cachegrind" "$BENCH" "$name"
}

hot() {
    local name="${ARGUMENTS[1]:-}"
    verify_case "$name"

    if ! command -v callgrind_annotate >/dev/null 2>&1; then
        error "callgrind_annotate is not installed." true 126
    fi

    info "Where '$name' spends its instructions"
    valgrind --tool=callgrind --callgrind-out-file="$WORK/$name.callgrind" \
        "$BENCH" "$name" >/dev/null 2>&1
    callgrind_annotate --threshold=90 "$WORK/$name.callgrind" | sed -n '/file:function/,$p'
}

parse_arguments() {
    local command="${1:-table}"

    if [[ "$command" != "help" && "$command" != "version" ]]; then
        verify_setup
    fi
    if [[ $(type -t "$command") == "function" ]]; then
        "$command" "$@"
        exit 0
    fi

    error "Unknown command $command, make sure you are using the correct syntax"
    help
}

parse_arguments "${ARGUMENTS[@]}"
