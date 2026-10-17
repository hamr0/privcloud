#!/bin/bash
# Run every suite in tests/ (all *.sh except this file), print each suite's
# TOTAL line, and exit non-zero if any suite fails. A suite that fails also
# gets its FAIL lines printed.
# Run: bash tests/run-all.sh
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
self=$(basename "${BASH_SOURCE[0]}")
bad=0
for f in "$H"/*.sh; do
  n=$(basename "$f"); [ "$n" = "$self" ] && continue
  out=$(bash "$f" 2>&1); rc=$?
  total=$(grep -m1 '^TOTAL' <<<"$out")
  printf '%-26s %s\n' "$n" "${total:-(no TOTAL line)}"
  if [ "$rc" != 0 ]; then bad=1; echo "  ^ FAILED (exit $rc)"; grep '^FAIL' <<<"$out" | cut -c1-200 | sed 's/^/    /'; fi
done
[ "$bad" = 0 ] && echo "ALL SUITES PASSED" || echo "SOME SUITES FAILED"
exit "$bad"
