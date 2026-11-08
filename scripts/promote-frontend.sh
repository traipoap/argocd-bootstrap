#!/usr/bin/env bash
# promote-frontend.sh — blue/green + canary promotion for the my-app staging frontend.
#
# Edits the HTTPRoute backend weights in
#   apps/my-app/overlays/staging/patch-httproute.yaml
# and commits the change. ArgoCD (selfHeal: true) then syncs the new weights.
# Do NOT `kubectl patch` the live HTTPRoute directly — selfHeal reverts it.
#
#   ./scripts/promote-frontend.sh canary 25    # 25% -> green, 75% -> blue
#   ./scripts/promote-frontend.sh ship         # blue/green cutover: 100% -> green
#   ./scripts/promote-frontend.sh rollback     # back to 100% -> blue
set -euo pipefail

usage() {
  sed -n 's/^#   \.\///p' "$0" | sed -n '1,3p'
  exit 1
}

cmd="${1:-}"
pct="${2:-}"
case "$cmd" in
  canary)
    [[ "$pct" =~ ^[0-9]+$ ]] || { echo "pct must be an integer" >&2; exit 1; }
    (( pct >= 0 && pct <= 100 )) || { echo "pct must be 0..100" >&2; exit 1; }
    green=$pct
    blue=$((100 - pct))
    msg="canary: ${pct}% green / $((100 - pct))% blue"
    ;;
  ship)
    green=100; blue=0
    msg="blue/green cutover: 100% green"
    ;;
  rollback)
    green=0; blue=100
    msg="rollback: 100% blue"
    ;;
  *)
    usage
    ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$root/apps/my-app/overlays/staging/patch-httproute.yaml"
[[ -f "$target" ]] || { echo "not found: $target" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

before="$(cat "$target")"
python3 - "$target" "$blue" "$green" <<'EOF'
import re, sys

path, blue, green = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()

def set_weight(color, value):
    global s
    pattern = r"(name: frontend-%s-svc\s+port: 80\s+weight: )\d+" % color
    s, n = re.subn(pattern, lambda m: m.group(1) + value, s)
    assert n == 1, "expected exactly one '%s' backendRef, found %d" % (color, n)

set_weight("blue", blue)
set_weight("green", green)
open(path, "w").write(s)
EOF

if [[ "$(cat "$target")" == "$before" ]]; then
  echo "Weights already blue=${blue} / green=${green}; nothing to do."
  exit 0
fi

git -C "$root" add "$target"
git -C "$root" commit -m "staging/frontend: ${msg}"

echo
echo "Committed. Push to let ArgoCD sync the cutover:"
echo "  git -C \"$root\" push"
echo
echo "Then verify:"
echo "  kubectl -n staging get pods -l app=frontend -o wide"
echo "  kubectl -n staging get httproute app-httproute -o yaml | grep -A3 weight"
echo "  curl -s -o /dev/null -w '%{http_code}\\n' http://k3s-origin.traipoap.com/"
