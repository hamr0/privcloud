#!/bin/bash
# Self-test of tests/lib.sh (check, check_total, extract_fn, the stub builders).
# Run: bash tests/lib-selftest.sh   (non-zero on any failure)
# LIB=<file> tests another harness (fail-first check against an old extractor).
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "${LIB:-$H/lib.sh}"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
# Never let a hanging extractor hang the suite.
ex() { timeout 5 bash -c '. "$1"; shift; extract_fn "$@"' _ "${LIB:-$H/lib.sh}" "$@"; }

cat > "$T/fix.sh" <<'X'
alpha() {
    echo alpha-body
    if true; then
        echo nested
    fi
}
oneliner() { echo one; }
beta() { # trailing comment on the opener
    echo beta-body
}
oneliner_c() { echo oc; }   # trailing comment after the close
gamma() {
    cat <<'EOT'
}
not the end
EOT
    echo gamma-after
}
delta() {
    echo here-string <<<"x"
    echo delta-after
}
_foo_bar() { echo prefix-sibling; }
_foo() { echo the-real-foo; }
last() {
    echo last-body
}
X
A=$(ex alpha "$T/fix.sh");  RC=$?
check 1a "multi-line function: exactly its own body, not the next function" '[ $RC = 0 ] && [ "$(tail -1 <<<"$A")" = "}" ] && [[ "$A" == *nested* && "$A" != *oneliner* ]] && [ "$(wc -l <<<"$A")" = 6 ]'
A=$(ex oneliner "$T/fix.sh"); RC=$?
check 1b "one-liner followed by another function: only the one-liner" '[ $RC = 0 ] && [ "$A" = "oneliner() { echo one; }" ]'
A=$(ex beta "$T/fix.sh")
check 1c "opener with a trailing comment still runs to its own closing brace" '[ "$(wc -l <<<"$A")" = 3 ] && [[ "$A" != *oneliner_c* ]]'
A=$(ex oneliner_c "$T/fix.sh")
check 1d "one-liner with a trailing comment after the brace: one line" '[ "$(wc -l <<<"$A")" = 1 ] && [[ "$A" == oneliner_c*echo\ oc* ]]'
A=$(ex gamma "$T/fix.sh")
check 1e "a col-0 } inside a heredoc does not end the function" '[[ "$A" == *gamma-after* ]] && [ "$(tail -1 <<<"$A")" = "}" ] && [[ "$A" != *delta* ]]'
A=$(ex delta "$T/fix.sh")
check 1f "a <<< here-string is not read as a heredoc" '[[ "$A" == *delta-after* ]] && [ "$(wc -l <<<"$A")" = 4 ] && [[ "$A" != *_foo* ]]'
A=$(ex _foo "$T/fix.sh")
check 1g "name match is exact (_foo is not _foo_bar)" '[ "$A" = "_foo() { echo the-real-foo; }" ]'
A=$(ex last "$T/fix.sh")
check 1h "last function in the file" '[ "$(wc -l <<<"$A")" = 3 ] && [ "$(tail -1 <<<"$A")" = "}" ]'

# renamed function: asking for the old name finds nothing and must not hang or take the next one
sed 's/^alpha()/alpha_renamed()/' "$T/fix.sh" > "$T/renamed.sh"
A=$(ex alpha "$T/renamed.sh"); RC=$?
check 2a "renamed function: nothing printed, rc 1 (does not swallow the next function, does not hang)" '[ $RC = 1 ] && [ -z "$A" ]'
printf 'broken() {\n  echo never closed\n' > "$T/open.sh"
A=$(ex broken "$T/open.sh"); RC=$?
check 2b "function that never closes: rc 1, not a silent success" '[ $RC = 1 ]'
A=$(ex nosuchfn "$T/fix.sh"); RC=$?
check 2c "unknown name: rc 1, empty" '[ $RC = 1 ] && [ -z "$A" ]'

# SETUP_SH is the default file (fail-first runs against old code)
A=$(SETUP_SH="$T/fix.sh" ex oneliner); RC=$?
check 3a "FILE omitted: SETUP_SH is honoured" '[ $RC = 0 ] && [ "$A" = "oneliner() { echo one; }" ]'
A=$(ex ok); RC=$?
check 3b "FILE and SETUP_SH omitted: defaults to the repo's setup.sh" '[ $RC = 0 ] && [[ "$A" == ok\(\)* ]]'

# check / check_total
OUT=$(bash -c '. "$1"; RC=7 X=q CHECK_DIAG="rc=\$RC x=\$X"; check a "good" true; check b "bad" false; check_total; echo "st=$?"' _ "${LIB:-$H/lib.sh}")
check 4a "check: PASS line, FAIL line with the lazily expanded diag, TOTAL line, nonzero status" '[[ "$OUT" == *"PASS  a  good"* && "$OUT" == *"FAIL  b  bad  [rc=7 x=q]"* && "$OUT" == *"TOTAL: 1 passed, 1 failed"* && "$OUT" == *"st=1" ]]'
OUT=$(bash -c '. "$1"; check a "good" true; check_total; echo "st=$?"' _ "${LIB:-$H/lib.sh}")
check 4b "check_total on all-pass: status 0, FAIL line without diag has no brackets" '[[ "$OUT" == *"TOTAL: 1 passed, 0 failed"* && "$OUT" == *"st=0" ]]'

# stub builders
mkdir -p "$T/bin"
stub_findmnt ok '$FM_ROOT' /dev/sdb1 stub '$FM_ROOT' systemd-1
export FM_ROOT=/mnt/x
a=$("$T/bin/findmnt" --target /p -o TARGET); b=$("$T/bin/findmnt" -no SOURCE /p); c=$(FM_MODE=stub "$T/bin/findmnt" -no SOURCE /p)
check 5a "stub_findmnt: TARGET call, SOURCE call, mode switch via FM_MODE, \$VAR expanded at run time" '[ "$a" = /mnt/x ] && [ "$b" = /dev/sdb1 ] && [ "$c" = systemd-1 ]'
stub_docker <<'X'
echo "docker:$*"
X
stub_firewall_cmd 'echo "fw:$*"'
check 5b "stub_docker (stdin body) and stub_firewall_cmd (arg body): executable, run" '[ "$("$T/bin/docker" ps)" = "docker:ps" ] && [ "$("$T/bin/firewall-cmd" --list-all)" = "fw:--list-all" ] && [ -x "$T/bin/docker" ]'

canary() { false; echo reached; }
errexit_here canary
check 6a "errexit_here: errexit is live inside the function (a failing command aborts it before the next line)" '[ $RC = 1 ] && [[ "$OUT" != *reached* ]]'
errexit_here echo hi
check 6b "errexit_here: a clean command passes its output and rc 0" '[ $RC = 0 ] && [ "$OUT" = hi ]'
mkdir -p "$T/app"; printf 'canary() { false; echo reached; }\n[ "$1" = --run ] && { "$2"; exit $?; }\n' > "$T/app/run.sh"
run_errexit canary
check 6c "run_errexit: loads run.sh minus the dispatcher and aborts like --run under set -e" '[ $RC = 1 ] && [[ "$OUT" != *reached* ]]'

check_total
