#!/bin/bash
# Stale menu-number references (D29): each string must point at a menu item that
# exists. Greps setup.sh / customer-guide.md against the live menu text. D8: the
# laptop main menu order and every `federver -> N` hint; D9: run_step's header.
# Run: bash tests/menu-refs.sh   (non-zero on any failure)
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S=${SETUP_SH:-$H/../setup.sh}; G=${GUIDE:-$H/../customer-guide.md}
R=$H/..
. "$H/lib.sh"
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
check 1a "main menu offers 'Run all (3-7)'" 'grep -q "Run all (3-7)" "$S"'
check 1b "post-install text points at Run all (3-7), not 'steps 3-11'" '! grep -q "steps 3-11" "$S" && grep -q "continue with .*Run all (3-7)" "$S"'
check 2a "menu: option 13 is Manage Syncthing" 'grep -q "13)\${NC} Manage Syncthing" "$S"'
check 2b "no 'option 14 handled it' (14 is not Syncthing)" '! grep -q "option 14 handled it" "$S" && grep -q "Laptop is already installed (option 13 handled it)" "$S"'
check 3a "guide: Syncthing stop path is 13 -> 4 (Stop both)" 'grep -q "Forgot the GUI password.*stop the container (\`federver → 13 → 4\`)" "$G"'
check 3b "Syncthing menu: option 4 is Stop both" 'grep -q "4)\${NC} Stop both" "$S"'
check 4a "repo dir is privcloud, not federver" '! grep -q "cd federver" "$S" && grep -q "cd privcloud && ./setup.sh" "$S"'

# D8 main-menu order: run the real _show_laptop_menu, read the real dispatcher text
(GREEN= RED= YELLOW= BLUE= BOLD= DIM= NC=; _show_menu_header() { :; }
 eval "$(extract_fn _show_laptop_menu "$S")"; _show_laptop_menu) 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' > "$T/menu"
sed -n '/^    _resolve_server_endpoint/,$p' "$S" > "$T/dispatch"
SEQ=$(grep -oE '^ +[0-9]+\)' "$T/menu" | tr -dc '0-9\n' | paste -sd, -)
CHECK_DIAG='seq=$SEQ'
check 5a "menu numbers run 1..17 in order, no letter key for Immich" '[ "$SEQ" = "1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17" ] && ! grep -qE "^ +i\)|i\)  Immich" "$T/menu"'
check 5b "Immich sits in Extras right after Tailscale; no separate Immich section; Tools last" '! grep -q "Immich photo management" "$T/menu" && grep -A1 "^ *8) *Manage Tailscale" "$T/menu" | grep -q "^ *9) *Manage Immich" && [ "$(grep -n -- "-- Tools --" "$T/menu" | cut -d: -f1)" -gt "$(grep -n " 15)" "$T/menu" | cut -d: -f1)" ]'
bad=""
for n in 8 9 10 11 12 13 14 15 16 17; do
  title=$(grep -E "^ +$n\\)" "$T/menu" | sed -E "s/^ +$n\\) +//; s/ +←.*//; s/ +\$//")
  grep -qF "$n) run_step \"[$n] $title\"" <(sed -E 's/^ +//; s/\)  +/) /' "$T/dispatch") || bad="$bad $n:'$title'"
done
CHECK_DIAG='mismatch:$bad'
check 5c "dispatcher label of every item 8-17 matches the menu title at the same number" '[ -z "$bad" ]'
CHECK_DIAG=
check 5d "9 opens Manage Immich; the i key is gone from the dispatcher" 'grep -qE "^ +9\) +run_step \"\[9\] Manage Immich\" step_immich" "$T/dispatch" && ! grep -qE "^ +i\) +run_step" "$T/dispatch"'

# D8 stale references: every `federver -> N` hint points at a real main-menu number
SCAN=$(cd "$R" && ls setup.sh README.md CLAUDE.md customer-guide.md docker-compose.yml .env.example scripts/*.sh docs/product/prd-*.md docs/wiki/*.md 2>/dev/null)
REFS=$(cd "$R" && grep -hoE "federver[\`\"'*]*(\\\$\{NC\})? *(->|→) *(\\\$\{BOLD\})?[0-9a-z]+( *(->|→) *[0-9]+)?" $SCAN)
STALE=$( { grep -E "(->|→) *(\\\$\{BOLD\})?i( |\$)" <<<"$REFS"; grep -E "(->|→) *(\\\$\{BOLD\})?(1[89]|[2-9][0-9])( |\$)" <<<"$REFS"; grep -E "(->|→) *(\\\$\{BOLD\})?(14|15|17) *(->|→) *[0-9]" <<<"$REFS"; } | head -5 | paste -sd'|' -)
CHECK_DIAG='stale: $STALE'
check 6a "no 'federver -> i', no number above 17, no submenu step under 14/15/17 (they have none)" '[ -z "$STALE" ] && [ -n "$REFS" ]'
CHECK_DIAG=
check 6b "pinned hints: Tailscale 8, phone 15, pass 17 in setup.sh" 'grep -q "federver -> 15\${NC} again" "$S" && grep -q "run federver → 17 (Save to pass)" "$S" && grep -q "run federver -> 8 first" "$S" && grep -q "Run \${BOLD}federver → 8\${NC}" "$S"'

# D9 header on every screen: run_step clears, prints the federver banner, then the step name
(GREEN= RED= YELLOW= BLUE= BOLD= DIM= NC=; DRY_RUN=0; FEDERVER_VERSION=9.9.9; clear() { echo "[CLEARED]"; }; _is_server() { return 1; }
 eval "$(extract_fn _show_menu_header "$S")"; eval "$(extract_fn run_step "$S")"
 mystep() { echo "step body"; }; run_step "[5] Install Docker" mystep </dev/null) > "$T/step" 2>&1
CHECK_DIAG='out=$(cat "$T/step")'
check 7a "run_step: cleared, banner (name, version, laptop, tagline), step name, then the body, in that order" 'awk "/CLEARED/{a=1} /federver v9.9.9.*laptop/{b=NR} /One box. Every service/{c=NR} /=== \[5\] Install Docker ===/{d=NR} /step body/{e=NR} END{exit !(a&&b&&b<c&&c<d&&d<e)}" "$T/step"'
CHECK_DIAG=
check 7b "run_step does not clear by itself (the banner function is the one place that clears)" '! extract_fn run_step "$S" | grep -qE "^ +clear$"'

# 8 the server hop (_on_server) runs ssh through the wrapper with LogLevel=ERROR: no "Connection to <ip> closed."
# after every step, while real connection errors (level ERROR) still print. (-q would hide those too.)
check 8a "the ssh() wrapper itself passes LogLevel=ERROR (not -q): every hop is quiet, errors stay" '! extract_fn ssh "$S" | grep -q -- " -q" && (export _SSH_OPTS="-o ConnectTimeout=8"; mkdir -p "$T/bin"; printf "#!/bin/bash\necho \"\$*\"\n" > "$T/bin/ssh"; chmod +x "$T/bin/ssh"; eval "$(extract_fn ssh "$S")"; PATH="$T/bin:$PATH"; [[ "$(ssh -t host cmd)" == *"-o LogLevel=ERROR"*"-o ConnectTimeout=8"*"-t host cmd"* ]])'
check 8b "_on_server hop: ssh -t via the wrapper (never 'command ssh'), no per-call LogLevel copy" 'extract_fn _on_server "$S" | grep -q "ssh -t \"\$SERVER_USER@\$SERVER_IP\"" && ! extract_fn _on_server "$S" | grep -q "command ssh\|LogLevel"'
check 9a "no hardcoded /mnt/data example in the sync direction menu or the Immich path prompt (public repo: generic wording)" '! grep -E "Server: +server → server|New Immich path" "$S" | grep -q "/mnt/data"'
check_total
