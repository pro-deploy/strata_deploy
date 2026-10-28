#!/usr/bin/env bash
# Runs the firewall block of strata-2xa10/install-server.sh, verbatim, in an Ubuntu 24.04 container and checks from two
# client containers which ports are reachable, in both API modes, on a re-run and on the way back.
set -uo pipefail
KIT=${1:-$(cd "$(dirname "$0")/../../strata-2xa10" && pwd)}   # path to strata-2xa10
HERE=$(cd "$(dirname "$0")" && pwd)
NET=strata-fwtest
T=172.30.0.10 C1=172.30.0.20 C2=172.30.0.21
fail=0

# The block under test: from the "# Firewall:" comment up to the line before "systemctl daemon-reload".
awk '/^# Firewall:/ {on = 1} /^systemctl daemon-reload/ {on = 0} on' "$KIT/install-server.sh" > "$HERE/fw-block.sh"; trap 'rm -f "$HERE/fw-block.sh"' EXIT
echo "block under test: $(wc -l < "$HERE/fw-block.sh") lines of install-server.sh"

docker rm -f fw-target fw-c1 fw-c2 >/dev/null 2>&1
docker network rm $NET >/dev/null 2>&1
docker network create --subnet 172.30.0.0/24 $NET >/dev/null
docker build -q -t strata-fwtest "$HERE" >/dev/null || exit 1
docker run -d --name fw-target --network $NET --ip $T --privileged -v "$HERE/fw-block.sh:/fw-block.sh:ro" strata-fwtest \
  bash -c '/usr/sbin/sshd; python3 -m http.server 18080 >/dev/null 2>&1 & python3 -m http.server 19100 >/dev/null 2>&1 & sleep infinity' >/dev/null
for c in fw-c1:$C1 fw-c2:$C2; do
  docker run -d --name "${c%%:*}" --network $NET --ip "${c#*:}" strata-fwtest sleep infinity >/dev/null
done
sleep 2

apply() {   # apply SSH_PORT PORT API_FROM DEPLOY_FROM: runs the block as install-server.sh would (set -euo pipefail)
  docker exec -e SSH_PORT="$1" -e PORT="$2" -e API_FROM="$3" -e DEPLOY_FROM="$4" fw-target \
    bash -c 'set -euo pipefail; source /fw-block.sh' 2>&1 | grep -v -E '^(Get:|Hit:|Fetched|Reading|Building|Selecting|Preparing|Unpacking|Setting up|Processing|Created symlink|debconf|Need to get|After this|The following|  )' | sed 's/^/    | /'
  echo "    rc=${PIPESTATUS[0]}"
}
probe() {   # probe CLIENT PORT EXPECT(open|closed)
  local got
  if docker exec "$1" timeout 3 bash -c "</dev/tcp/$T/$2" 2>/dev/null; then got=open; else got=closed; fi
  if [[ $got == "$3" ]]; then echo "    ok    $1 -> $2 $got"; else echo "    FAIL  $1 -> $2 $got (expected $3)"; fail=1; fi
}
rules() { docker exec fw-target ufw status | grep -c ALLOW; }

echo "before: no firewall"
probe fw-c1 19100 open

echo "A. API open to everyone"
apply 22 18080 "" ""
for c in fw-c1 fw-c2; do probe $c 22 open; probe $c 2222 open; probe $c 18080 open; probe $c 19100 closed; done
docker exec fw-target ufw status | sed 's/^/    /'

echo "B. API only from $C1 (deploy run from $C2)"
apply 22 18080 "$C1" ""
probe fw-c1 18080 open; probe fw-c2 18080 closed; probe fw-c2 22 open; probe fw-c1 19100 closed
nB=$(rules); echo "    ALLOW rules: $nB"

echo "C. same as B again (re-run must not pile up rules)"
apply 22 18080 "$C1" ""
nC=$(rules); echo "    ALLOW rules: $nC"
[[ $nB == "$nC" ]] && echo "    ok    rule count unchanged" || { echo "    FAIL  rule count $nB -> $nC"; fail=1; }

echo "D. API from $C1, deploy run from $C2 (its address is let in too)"
apply 22 18080 "$C1" "$C2"
probe fw-c1 18080 open; probe fw-c2 18080 open

echo "E. back to everyone: the limited rules are gone"
apply 22 18080 "" ""
probe fw-c2 18080 open
docker exec fw-target ufw status | grep -q 'ALLOW IN    172.30' && { echo "    FAIL  limited rules left"; fail=1; } || echo "    ok    no limited rules left"

echo "F. a rule the admin added by hand survives a re-run"
docker exec fw-target ufw allow 8443/tcp >/dev/null
apply 22 18080 "" ""
docker exec fw-target ufw status | grep -q '^8443/tcp' && echo "    ok    8443/tcp kept" || { echo "    FAIL  8443/tcp removed"; fail=1; }

echo "fail2ban: $(docker exec fw-target bash -c 'command -v fail2ban-client >/dev/null && echo installed; cat /etc/fail2ban/jail.d/strata-sshd.local 2>/dev/null | tr "\n" " "')"

docker rm -f fw-target fw-c1 fw-c2 >/dev/null; docker network rm $NET >/dev/null
[[ $fail == 0 ]] && echo "RESULT: all checks passed" || echo "RESULT: some checks FAILED"
exit $fail
