#!/bin/sh
# Run every regression test. Exits non-zero if any fails, so it can gate a build.
#
#   sh tools/t_all.sh            (quiet: one line per suite)
#   sh tools/t_all.sh -v         (verbose: every case)
#
# Needs only perl + DBD::SQLite. No LMS install, no server — see tools/t_stubs.pl.
cd "$(dirname "$0")/.." || exit 2
verbose=""
[ "$1" = "-v" ] && verbose=1

status=0
for t in tools/t_*.pl; do
    case "$t" in tools/t_stubs.pl) continue ;; esac
    if [ -n "$verbose" ]; then
        printf '\n===== %s\n' "$t"
        perl "$t" || status=1
    else
        out=$(perl "$t" 2>&1)
        if [ $? -eq 0 ]; then
            printf '%-26s %s\n' "$(basename "$t")" "$(printf '%s' "$out" | tail -1)"
        else
            status=1
            printf '%-26s FAILED\n' "$(basename "$t")"
            printf '%s\n' "$out" | grep -E '^FAIL|died|Can.t' | head -20
        fi
    fi
done


[ $status -eq 0 ] && echo "\nall suites passed" || echo "\nFAILURES — see above"
exit $status
