#!/bin/bash
# Shared test harness: source it from every suite (. "$H/lib.sh"), never run it.
#   check ID DESC COND   COND is eval'd; prints PASS/FAIL, counts them. On FAIL the
#                        suite's CHECK_DIAG string (eval'd lazily, e.g. 'rc=$RC')
#                        is appended in brackets so a failure explains itself.
#   check_total          prints the "TOTAL: N passed, M failed" line run-all.sh
#                        greps for; its status is the suite's exit status:
#                        end every suite with it.
#   extract_fn NAME [FILE]   prints function NAME from FILE (default: $SETUP_SH or
#                        ../setup.sh, so a fail-first run against old code works).
#                        Ends at the function's own closing brace: a col-0 "}",
#                        or the same line for a one-liner; heredoc bodies are
#                        skipped (a col-0 "}" inside one does not end it). Prints
#                        nothing and returns 1 when NAME is missing or never closes.
#   stub_cmd NAME [BODY] / stub_findmnt / stub_docker / stub_firewall_cmd
#                        write an executable stub into $T/bin (BODY as the
#                        argument, or on stdin). Only the mechanism is shared;
#                        what a stub answers stays in the suite.
#   stub_findmnt MODE TARGET SOURCE [MODE TARGET SOURCE ...]
#                        findmnt stub answering by $FM_MODE (default: the first MODE):
#                        --target-ish calls get TARGET, others SOURCE. TARGET and
#                        SOURCE are double-quoted in the stub, so '$VAR' is expanded
#                        when the stub runs.
#   errexit_here FN [ARGS...]  same, for functions already loaded in the test shell: FN runs in
#                        a `( set -e; ... )` subshell at top level; sets OUT and RC.
#   run_errexit FN [ARGS...]   runs FN the way `setup.sh --run FN` does on the server:
#                        in a fresh `bash -c 'set -e; ...'` that loads the suite's
#                        extracted functions ($T/app/run.sh minus its dispatcher line)
#                        and calls FN at top level, so errexit applies INSIDE FN (a
#                        plain call from a test has no set -e, which hid aborts). stdin
#                        is the caller's; sets OUT (stdout+stderr) and RC.
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PASS=0; FAILN=0
CHECK_DIAG=${CHECK_DIAG:-}

check() { # id desc cond
  if eval "$3"; then echo "PASS  $1  $2"; PASS=$((PASS+1))
  else echo "FAIL  $1  $2${CHECK_DIAG:+  [$(eval "echo \"$CHECK_DIAG\"" 2>&1)]}"; FAILN=$((FAILN+1)); fi
}
check_total() { echo ""; echo "TOTAL: $PASS passed, $FAILN failed"; [ "$FAILN" = 0 ]; }

extract_fn() { # name [file]
  awk -v n="$1" '
    function opens(s) { return s ~ /\{[ \t]*(#.*)?$/ }
    function closes(s) { return s ~ /\}[ \t]*(#.*)?$/ }
    hd != "" { print; t=$0; sub(/^\t+/, "", t); if (t == hd || $0 == hd) hd=""; next }
    p == 0 { if (index($0, n "()") == 1 && substr($0, length(n)+3, 1) ~ /^[ \t{]?$/) {
        p=1; print
        if (closes($0) && !opens($0)) { done=1; exit }
        heredoc($0) }
      next }
    { print
      if ($0 ~ /^\}/) { done=1; exit }
      heredoc($0) }
    function heredoc(s,   i, tag) {   # a "<<TAG" (not "<<<") starts a body that ends at TAG
      i = match(s, /<<-?[ \t]*[\47"\\]?[A-Za-z_][A-Za-z_0-9]*/)
      if (i == 0 || (i > 1 && substr(s, i-1, 1) == "<")) return
      tag = substr(s, RSTART, RLENGTH); sub(/^<<-?[ \t]*[\47"\\]?/, "", tag); hd = tag }
    END { exit !done }' "${2:-${SETUP_SH:-$LIB_DIR/../setup.sh}}"
}

stub_cmd() { # name [body]  (body on stdin when omitted)
  local f="$T/bin/$1"; mkdir -p "$T/bin"
  { printf '#!/bin/bash\n'; if [ $# -ge 2 ]; then printf '%s\n' "$2"; else cat; fi; } > "$f"
  chmod +x "$f"
}
stub_docker()       { stub_cmd docker "$@"; }
stub_firewall_cmd() { stub_cmd firewall-cmd "$@"; }
stub_findmnt() {
  if [ $# -eq 0 ]; then stub_cmd findmnt; return; fi   # stdin body
  local body='case "$*" in *TARGET*) col=T;; *) col=S;; esac'$'\n''case "${FM_MODE:-'"$1"'}" in'$'\n'
  while [ $# -ge 3 ]; do
    body+="  $1) [ \$col = T ] && echo \"$2\" || echo \"$3\" ;;"$'\n'; shift 3
  done
  stub_cmd findmnt "$body"$'esac'
}

run_errexit() { # fn [args...]
  OUT=$(bash -c 'set -e; eval "$(sed "\$d" "$1")"; shift; "$@"; exit $?' _ "$T/app/run.sh" "$@" 2>&1); RC=$?
}
errexit_here() { # fn [args...]
  OUT=$( set -e; "$@" 2>&1 ); RC=$?
}
