#!/usr/bin/env bash
# Run on the destination server as root: Linux x86_64, NVIDIA GPUs, systemd. deploy.sh uploads this kit and writes
# strata.env (the model, the GPUs, the port and the pinned Strata commit).
# Installs the Strata source of that commit from GitHub into /opt/strata with its ready-made engine, downloads the chosen model (pinned revision, SHA-256
# checked by setup), runs one replica per GPU behind one keyed API and starts it as a systemd service with autostart.
# Re-running is safe: the API key, the model files and the run config's own additions are kept.
set -euo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$HERE/strata.env"
: "${STRATA_REPO:?strata.env must set STRATA_REPO}" "${STRATA_COMMIT:?}" "${FAMILY:?}" "${SIZE:?}" "${TAG:?}" "${SERVICE_NAME:?}" "${PORT:?}" "${GPUS:?}" "${REPLICAS:?}" "${PARALLEL:?}"
APP=/opt/strata
DATA=/opt/strata-data
KEY_FILE=/root/strata-api.key

[[ $EUID == 0 ]] || { echo 'Run as root on the destination server.' >&2; exit 1; }
command -v nvidia-smi >/dev/null || { echo 'Install an NVIDIA driver first.' >&2; exit 1; }
nvidia-smi --query-gpu=index,name,memory.total,pcie.link.width.current,driver_version --format=csv
gpus=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
(( gpus >= REPLICAS )) || { echo "$REPLICAS replicas need $REPLICAS GPUs, the server has $gpus." >&2; exit 1; }

# setup.sh needs Python 3.10+ with venv and ensurepip; it would call sudo for them, so root installs them here.
if ! python3 -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
  echo 'Installing python3-venv and python3-pip...'
  DEBIAN_FRONTEND=noninteractive apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 python3-venv python3-pip
fi

# The source of the pinned commit replaces the previous one; .venv, the engine, the configs and the logs stay.
mkdir -p "$APP" "$DATA"
echo "Downloading the Strata source $STRATA_REPO@$STRATA_COMMIT..."
curl -fsSL --retry 3 -o "$HERE/strata-src.tar.gz" "https://codeload.github.com/$STRATA_REPO/tar.gz/$STRATA_COMMIT"
tar -xzf "$HERE/strata-src.tar.gz" -C "$APP" --strip-components=1
[[ -f $HERE/deploy-info ]] && install -m 644 "$HERE/deploy-info" "$APP/deploy-info"

if [[ ! -s $KEY_FILE ]]; then
  (umask 077; python3 -c 'import secrets; print("sk-strata-" + secrets.token_urlsafe(32))' > "$KEY_FILE")
fi

# Setup without questions: the ready-made engine for these cards, the model and its run config; nothing starts yet.
# Qwen3.6 is set up on one card (its setup path is single-GPU), Flash-Next on all of them; the replicas below put one
# engine on each card in both cases.
gpu_args=(--gpu "${GPUS%%,*}")
[[ $FAMILY == qwen36 ]] || gpu_args=(--gpus "$GPUS" --replicas "$REPLICAS")
(cd "$APP" && ./setup.sh --setup --family "$FAMILY" --model "$SIZE" "${gpu_args[@]}" --parallel "$PARALLEL" \
  --vision no --host 0.0.0.0 --api-key "$(cat "$KEY_FILE")" --port "$PORT" --data-dir "$DATA" \
  --no-browser --no-start --yes)

cfg=$APP/strata-${TAG,,}.json
run=$APP/run-${TAG,,}.sh
[[ -f $cfg && -x $run ]] || { echo "setup did not write $cfg and $run." >&2; exit 1; }
# One replica per card for every model. replica_load_tokens 20000: agents share a long system prompt, and with the
# default 3000 every request went to the replica that already held it (measured on 3 x A10 with Flash-Next).
python3 - "$cfg" "$GPUS" "$REPLICAS" <<'PY'
import json, sys
path, gpus, replicas = sys.argv[1], [int(g) for g in sys.argv[2].split(",")], int(sys.argv[3])
cfg = json.load(open(path))
cfg["gpu"] = gpus
cfg["replicas"] = replicas
cfg["replica_load_tokens"] = 20000
json.dump(cfg, open(path, "w"), indent=2)
PY
chmod 600 "$cfg"

sed -e "s|@DESCRIPTION@|$SERVED_NAME ($FAMILY $SIZE), $REPLICAS replicas on GPUs $GPUS, API $PORT|" -e "s|@RUN@|$run|" \
  "$HERE/strata.service" > "/etc/systemd/system/$SERVICE_NAME.service"
chmod 644 "/etc/systemd/system/$SERVICE_NAME.service"
if [[ -d /etc/needrestart ]]; then
  install -D -m 644 "$HERE/90-strata.conf" /etc/needrestart/conf.d/90-strata.conf
fi
systemctl daemon-reload
systemctl enable "$SERVICE_NAME.service"
systemctl restart "$SERVICE_NAME.service"

# The port stays closed while the engines load the model into RAM and the GPUs, so failed probes are expected and stay
# silent; deploy.sh shows a loader from here on, and a progress line every minute keeps this log readable on its own.
echo 'Waiting for the model to load (usually 3-15 minutes)...'
ready=no
for i in $(seq 1 180); do
  if curl -fs -m 3 -o /dev/null "http://127.0.0.1:$PORT/health"; then ready=yes; break; fi
  systemctl is-active -q "$SERVICE_NAME.service" || { journalctl -u "$SERVICE_NAME" -n 40 --no-pager; exit 1; }
  (( i % 6 == 0 )) && echo "  still loading, $((i / 6)) min: $(journalctl -u "$SERVICE_NAME" -n 1 --no-pager -o cat 2>/dev/null | cut -c 1-120)"
  sleep 10
done
[[ $ready == yes ]] || { echo "The model did not answer on port $PORT within 30 minutes." >&2; journalctl -u "$SERVICE_NAME" -n 40 --no-pager; exit 1; }
echo "Ready: http://<server>:$PORT/v1, model $SERVED_NAME, key in $KEY_FILE"
