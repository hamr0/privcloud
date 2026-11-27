#!/bin/bash
# Stale menu-number references (D29): each string must point at a menu item that
# exists. Greps setup.sh / customer-guide.md against the live menu text.
# Run: bash tests/menu-refs.sh   (non-zero on any failure)
H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
S=${SETUP_SH:-$H/../setup.sh}; G=${GUIDE:-$H/../customer-guide.md}
. "$H/lib.sh"
check 1a "main menu offers 'Run all (3-7)'" 'grep -q "Run all (3-7)" "$S"'
check 1b "post-install text points at Run all (3-7), not 'steps 3-11'" '! grep -q "steps 3-11" "$S" && grep -q "continue with .*Run all (3-7)" "$S"'
check 2a "menu: option 12 is Manage Syncthing" 'grep -q "12)\${NC} Manage Syncthing" "$S"'
check 2b "no 'option 14 handled it' (14 is not Syncthing)" '! grep -q "option 14 handled it" "$S" && grep -q "Laptop is already installed (option 12 handled it)" "$S"'
check 3a "guide: Syncthing stop path is 12 -> 4 (Stop both), not 14 -> 6" 'grep -q "Forgot the GUI password.*stop the container (\`federver → 12 → 4\`)" "$G"'
check 3b "Syncthing menu: option 4 is Stop both" 'grep -q "4)\${NC} Stop both" "$S"'
check 4a "repo dir is privcloud, not federver" '! grep -q "cd federver" "$S" && grep -q "cd privcloud && ./setup.sh" "$S"'
check_total
