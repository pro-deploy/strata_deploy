#!/usr/bin/env bash
# Interactive deployment of the Strata engine with one of two models (Qwen3.6-35B-A3B or Qwen3.8-Flash-Next) from the
# kit in strata-2xa10. Asks for the server, the password, the model and the API port, validates every answer,
# checks the server (GPUs, RAM, disk, running model services), then uploads the kit together with the Strata source kept
# in this repository (strata/), runs install-server.sh there in the background, follows its log and shows a loader until
# the API answers. Nothing of Strata is downloaded from elsewhere. Runs on macOS (bash 3.2) and Linux. The password is never written to disk or to the saved answers.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KIT=$ROOT/strata-2xa10
SRC=$ROOT/strata
REMOTE_KIT=/root/strata-kit
SERVICE_NAME=strata
STATE_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/strata-deploy
STATE=$STATE_DIR/last.env

if [[ -t 1 ]]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B='' R='' G='' Y='' N=''; fi
say()  { printf '%s\n' "$*"; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %sготово:%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %sвнимание:%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '\n%sОшибка:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

[[ -t 0 ]] || die 'скрипт интерактивный, запустите его в терминале.'
for tool in ssh tar gzip curl; do command -v "$tool" >/dev/null || die "не найдена программа $tool."; done
[[ -f $KIT/install-server.sh && -f $KIT/strata-source.env ]] || die "не найден комплект установки в $KIT."
[[ -x $SRC/setup.sh && -f $SRC/setup.py ]] || die "не найден исходный код Strata в $SRC."
STRATA_REPO='' STRATA_COMMIT=''
while IFS='=' read -r k v; do
  case $k in STRATA_REPO|STRATA_COMMIT) printf -v "$k" '%s' "$v";; esac
done < "$KIT/strata-source.env"
[[ $STRATA_REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && $STRATA_COMMIT =~ ^[0-9a-f]{40}$ ]] \
  || die "в $KIT/strata-source.env должны быть STRATA_REPO (владелец/название) и STRATA_COMMIT (полный SHA из 40 символов)."
# The kit's release version (tag vX.Y.Z on the same commit); a ZIP download without git still carries it.
KIT_VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || true)
[[ $KIT_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "в $ROOT/VERSION должен быть номер версии вида 1.0.0."

# ---------- validators: each takes the answer and returns 0 when its format is right ----------

is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o
  for o in "${BASH_REMATCH[@]:1}"; do
    [[ $o =~ ^(0|[1-9][0-9]*)$ ]] && (( o <= 255 )) || return 1
  done
  [[ $1 != 0.0.0.0 && $1 != 255.255.255.255 ]]
}
is_host() {
  if [[ $1 =~ ^[0-9.]+$ ]]; then is_ipv4 "$1"; return; fi
  (( ${#1} <= 253 )) && [[ $1 =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}
is_port()    { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 )); }
is_api_port() { is_port "$1" && (( $1 >= 1024 )) && [[ $1 != "$SSH_PORT" ]]; }
is_user()    { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
is_menu()    { [[ $1 =~ ^[1-9][0-9]*$ ]] && (( $1 <= MENU_MAX )); }
is_yesno()   { case $1 in y|Y|yes|Yes|YES|д|Д|да|Да|ДА|n|N|no|No|NO|н|Н|нет|Нет|НЕТ) return 0;; esac; return 1; }

# ask VAR "question" "default" validator "what the right format is"
ask() {
  local __var=$1 __question=$2 __def=$3 __check=$4 __hint=$5 __answer
  while :; do
    if [[ -n $__def ]]; then
      read -r -p "  $__question [$__def]: " __answer || die 'ввод прерван.'
    else
      read -r -p "  $__question: " __answer || die 'ввод прерван.'
    fi
    __answer=$(trim "$__answer")
    [[ -z $__answer ]] && __answer=$__def
    if [[ -n $__answer ]] && "$__check" "$__answer"; then
      printf -v "$__var" '%s' "$__answer"
      return
    fi
    if [[ -z $__answer ]]; then say "    Значение обязательно. $__hint"; else say "    Неверный формат: «$__answer». $__hint"; fi
  done
}

# confirm "question" y|n: returns 0 for yes
confirm() {
  local answer
  ask answer "$1 (да/нет)" "$( [[ $2 == y ]] && echo да || echo нет )" is_yesno 'Ответьте «да» или «нет».'
  case $answer in y|Y|yes|Yes|YES|д|Д|да|Да|ДА) return 0;; esac
  return 1
}

# Saved answers from the previous run; only whitelisted keys are read, the password is never saved.
LAST_HOST='' LAST_SSH_PORT=22 LAST_USER=root LAST_MODEL=1 LAST_API_PORT=18080
if [[ -r $STATE ]]; then
  while IFS='=' read -r k v; do
    case $k in LAST_HOST|LAST_SSH_PORT|LAST_USER|LAST_MODEL|LAST_API_PORT) printf -v "$k" '%s' "$v";; esac
  done < "$STATE"
fi
[[ $LAST_MODEL == 1 || $LAST_MODEL == 2 ]] || LAST_MODEL=1

WORK=$(mktemp -d /tmp/strata-deploy.XXXXXX)
SSH_OPTS=(-o "ControlPath=$WORK/ctl" -o ServerAliveInterval=30 -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)
TARGET=''
cleanup() {
  [[ -n $TARGET && -S $WORK/ctl ]] && ssh "${SSH_OPTS[@]}" -O exit "$TARGET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

say "${B}Развёртывание сервера нейросети на движке Strata${N} (комплект strata_deploy v$KIT_VERSION)"
say 'Значение в квадратных скобках подставляется, если просто нажать Enter.'

# ---------- 1. Server and login ----------

head_ '1. Сервер'
ask HOST 'Адрес сервера (IPv4 или доменное имя)' "$LAST_HOST" is_host 'Пример: 203.0.113.10 или gpu.example.com; каждое число IPv4 от 0 до 255.'
ask SSH_PORT 'Порт SSH' "$LAST_SSH_PORT" is_port 'Целое число от 1 до 65535.'
ask SSH_USER 'Пользователь' "$LAST_USER" is_user 'Латинские строчные буквы, цифры, «_» и «-», начинается с буквы или «_», до 32 символов.'
TARGET=$SSH_USER@$HOST
SSH_OPTS+=(-p "$SSH_PORT")

openssh_has_askpass_force() {
  local v; v=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')
  # shellcheck disable=SC2086 # split "major minor"
  [[ -n $v ]] && set -- $v && (( $1 > 8 || ($1 == 8 && $2 >= 4) ))
}

connect_with_password() {
  local pw attempt
  openssh_has_askpass_force || command -v sshpass >/dev/null || die 'для входа по паролю нужен OpenSSH 8.4 или новее либо программа sshpass (brew install hudochenkov/sshpass/sshpass).'
  # The askpass helper prints the password from its environment, so it never lands in a file.
  printf '#!/bin/sh\nprintf "%%s\\n" "$STRATA_DEPLOY_PW"\n' > "$WORK/askpass"
  chmod 700 "$WORK/askpass"
  for attempt in 1 2 3; do
    read -r -s -p "  Пароль для $TARGET: " pw || die 'ввод прерван.'
    printf '\n'
    if [[ -z $pw ]]; then say '    Пароль не может быть пустым.'; continue; fi
    if openssh_has_askpass_force; then
      STRATA_DEPLOY_PW=$pw SSH_ASKPASS=$WORK/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-:0} \
        ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -o ControlPersist=yes -o NumberOfPasswordPrompts=1 \
        -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
        -fN "$TARGET" </dev/null 2>"$WORK/ssh.err" && { pw=; return 0; }
    else
      SSHPASS=$pw sshpass -e ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -o ControlPersist=yes \
        -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
        -fN "$TARGET" </dev/null 2>"$WORK/ssh.err" && { pw=; return 0; }
    fi
    say "    Не удалось войти (попытка $attempt из 3): $(tail -n 1 "$WORK/ssh.err")"
  done
  die "не удалось войти на $TARGET по паролю."
}

rsh() { ssh "${SSH_OPTS[@]}" "$TARGET" "$@"; }

say "  Подключение к $TARGET, порт $SSH_PORT..."
connect_with_password
rsh true || die 'соединение установлено, но команды на сервере не выполняются.'
ok "вход выполнен, отпечаток ключа сервера сохранён в ~/.ssh/known_hosts."

SUDO=''
if [[ $(rsh 'id -u') != 0 ]]; then
  rsh 'sudo -n true' 2>/dev/null || die "пользователю $SSH_USER нужны права root: войдите как root или настройте sudo без пароля."
  SUDO='sudo -n'
fi

# ---------- 2. What is on the server ----------

head_ '2. Проверка сервера'
FACTS=$(rsh "$SUDO bash -s" <<'REMOTE'
set +e
. /etc/os-release 2>/dev/null; echo "OS=$PRETTY_NAME"
echo "ARCH=$(uname -m)"
command -v systemctl >/dev/null && echo SYSTEMD=yes
command -v python3 >/dev/null && echo PYTHON=yes
command -v apt-get >/dev/null && echo APT=yes
if command -v nvidia-smi >/dev/null; then
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null | sed 's/^/GPU=/'
  echo "DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n 1)"
fi
echo "RAM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
echo "CPUS=$(nproc)"
mkdir -p /opt
echo "DISK_KB=$(df -Pk /opt | awk 'NR==2 {print $4}')"
[ -r /opt/strata/deploy-info ] && sed 's/^/INFO=/' /opt/strata/deploy-info
systemctl list-units --type=service --all --no-legend --plain 'strata*' 'vllm-*' 2>/dev/null | awk '{print "UNIT=" $1 " " $3}'
REMOTE
)
OS='' ARCH='' SYSTEMD='' PYTHON='' APT='' DRIVER='' RAM_KB=0 CPUS=0 DISK_KB=0 GPU_COUNT=0 GPU_MIB=0 GPU_LIST='' INFO='' UNITS=''
while IFS='=' read -r k v; do
  case $k in
    OS|ARCH|SYSTEMD|PYTHON|APT|DRIVER|RAM_KB|CPUS|DISK_KB) printf -v "$k" '%s' "$v";;
    GPU) GPU_COUNT=$((GPU_COUNT + 1)); GPU_LIST+="      $((GPU_COUNT - 1))) ${v%,*}, ${v##*, } МиБ"$'\n'
         mib=${v##*, }; mib=${mib//[^0-9]/}
         if (( GPU_MIB == 0 || mib < GPU_MIB )); then GPU_MIB=$mib; fi;;
    INFO) INFO+="      $v"$'\n';;
    UNIT) UNITS+="$v"$'\n';;
  esac
done <<< "$FACTS"
RAM_GIB=$(( RAM_KB / 1048576 ))
DISK_GIB=$(( DISK_KB / 1048576 ))

say "  ОС: ${OS:-неизвестно}, архитектура $ARCH, процессор $CPUS потоков, оперативная память $RAM_GIB ГиБ"
[[ $ARCH == x86_64 ]] || die 'комплект поддерживает только серверы x86_64.'
[[ $SYSTEMD == yes ]] || die 'на сервере нет systemd.'
[[ $PYTHON == yes || $APT == yes ]] || die 'на сервере нет python3 и нет apt-get, чтобы его установить.'
(( GPU_COUNT > 0 )) || die 'на сервере не найден драйвер NVIDIA или видеокарты (nvidia-smi не отвечает).'
say "  Видеокарты ($GPU_COUNT шт., драйвер $DRIVER):"
printf '%s' "$GPU_LIST"
say "  Свободно на диске /opt: $DISK_GIB ГиБ"
if [[ -n $INFO ]]; then say '  Сейчас развёрнуто:'; printf '%s' "$INFO"; else say '  Предыдущих развёртываний Strata этим скриптом не найдено.'; fi
if [[ -n $UNITS ]]; then say '  Службы нейросетей на сервере:'; printf '%s' "$UNITS" | sed '/^$/d; s/^/      /'; fi

# ---------- 3. Model ----------
# Both models run one Strata engine per GPU (replicas) behind one API. RAM_PER and DISK_NEED are estimates: Flash-Next
# IQ3_XXS pinned about 40 GB of RAM per replica on A10s; Qwen3.6 keeps in RAM the experts that do not fit its card.

head_ '3. Нейросеть'
say '    1) Qwen3.6-35B-A3B (UD-Q4_K_XL): 35 млрд параметров (3 млрд активных), скачивание 23 ГБ, рассуждения и вызов инструментов.'
say '    2) Qwen3.8-Flash-Next (IQ3_XXS): 125 млрд параметров, скачивание 76 ГБ, рассуждения и вызов инструментов; эксперты в оперативной памяти сервера.'
MENU_MAX=2
ask MODEL_CHOICE 'Выберите нейросеть' "$LAST_MODEL" is_menu 'Введите 1 или 2.'
case $MODEL_CHOICE in
  1) MODEL_TITLE='Qwen3.6-35B-A3B' FAMILY=qwen36 SIZE=UD-Q4_K_XL TAG=qwen36-UD-Q4_K_XL SERVED_NAME=qwen3.6-35b-a3b ALIAS=qwen3.6-35b-a3b-ud-q4_k_xl
     PARALLEL=4 DOWNLOAD_GB=23 DISK_NEED=55 RAM_PER=24;;
  2) MODEL_TITLE='Qwen3.8-Flash-Next' FAMILY=qwen SIZE=IQ3_XXS TAG=IQ3_XXS SERVED_NAME=qwen3.8-flash-next ALIAS=qwen3.8-flash-next-iq3_xxs
     PARALLEL=4 DOWNLOAD_GB=76 DISK_NEED=180 RAM_PER=40;;
esac

REPLICAS=$GPU_COUNT
GPUS=0
for (( g = 1; g < GPU_COUNT; g++ )); do GPUS+=",$g"; done
RAM_NEED=$(( RAM_PER * REPLICAS + 16 ))
say "  Профиль: по одной копии модели на каждую из $REPLICAS видеокарт ($GPUS), до $PARALLEL одновременных запросов на каждую."
if (( RAM_GIB < RAM_NEED )); then
  warn "для $MODEL_TITLE на $REPLICAS видеокартах нужно около $RAM_NEED ГиБ оперативной памяти, на сервере $RAM_GIB ГиБ. Модель может не запуститься или работать медленно."
  confirm 'Всё равно продолжить?' n || die 'развёртывание отменено.'
fi
if (( DISK_GIB < DISK_NEED )); then
  warn "нужно около $DISK_NEED ГиБ на диске /opt, свободно $DISK_GIB ГиБ. Если модель уже скачана в /opt/strata-data, места может хватить."
  confirm 'Продолжить?' n || die 'развёртывание отменено.'
fi

head_ '4. Порт API'
ask API_PORT 'Порт API' "$LAST_API_PORT" is_api_port "Целое число от 1024 до 65535, не совпадающее с портом SSH ($SSH_PORT)."

# Any other model service (an earlier vLLM deployment, another Strata unit) holds the GPUs and has to stop.
CONFLICTS=$(printf '%s' "$UNITS" | awk -v keep="$SERVICE_NAME.service" 'NF && $1 != keep && $2 != "inactive" {print $1}')
if [[ -n $CONFLICTS ]]; then
  warn "на сервере работают другие службы нейросетей: $(printf '%s' "$CONFLICTS" | tr '\n' ' ')"
  say '  Они занимают те же видеокарты, поэтому их нужно остановить и отключить автозапуск.'
  confirm 'Остановить и отключить их?' y || die 'развёртывание отменено: остановите эти службы вручную или выберите другой сервер.'
fi

# ---------- 5. Version record and summary ----------
# The server gets the Strata source of strata/; this repository's commit identifies it, with "-dirty" when strata/, the
# kit or deploy.sh has uncommitted edits ("unknown" outside a git checkout, e.g. a ZIP download).

KIT_COMMIT=$(git -C "$ROOT" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
if [[ $KIT_COMMIT != unknown && -n $(git -C "$ROOT" status --porcelain -- "$SRC" "$KIT" "$ROOT/deploy.sh" "$ROOT/VERSION" 2>/dev/null) ]]; then
  KIT_COMMIT=$KIT_COMMIT-dirty
fi
STRATA_SHORT=${STRATA_COMMIT:0:12}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

head_ '5. Проверьте параметры'
say "  Сервер:            $TARGET, порт SSH $SSH_PORT"
say "  Движок:            Strata из этого репозитория (снимок $STRATA_REPO@$STRATA_SHORT), движок компилируется на сервере под его видеокарты"
say "  Комплект:          strata_deploy v$KIT_VERSION (коммит $KIT_COMMIT)"
say "  Модель:            $MODEL_TITLE $SIZE, скачивание около $DOWNLOAD_GB ГБ"
say "  Имя в API:         $SERVED_NAME (также принимается $ALIAS)"
say "  Видеокарты:        $GPUS, по одной копии модели на каждой, до $PARALLEL запросов на копию"
say "  Каталоги:          /opt/strata (программа), /opt/strata-data (модели)"
say "  Служба systemd:    $SERVICE_NAME.service"
say "  API:               http://$HOST:$API_PORT/v1"
confirm 'Начать развёртывание?' y || die 'развёртывание отменено, на сервере ничего не изменено.'

# Remember the answers (never the password) for the next run.
mkdir -p "$STATE_DIR"
printf '%s\n' "LAST_HOST=$HOST" "LAST_SSH_PORT=$SSH_PORT" "LAST_USER=$SSH_USER" \
  "LAST_MODEL=$MODEL_CHOICE" "LAST_API_PORT=$API_PORT" > "$STATE"

# ---------- 6. Upload and install ----------

head_ '6. Установка'
STAGE=$WORK/strata-kit
mkdir -p "$STAGE"
cp "$KIT/install-server.sh" "$KIT/strata.service" "$KIT/90-strata.conf" "$STAGE/"
COPYFILE_DISABLE=1 tar -C "$SRC" --exclude .DS_Store -cf - . | gzip -1 > "$STAGE/strata-src.tar.gz"
cat > "$STAGE/strata.env" <<EOF
STRATA_REPO=$STRATA_REPO
STRATA_COMMIT=$STRATA_COMMIT
FAMILY=$FAMILY
SIZE=$SIZE
TAG=$TAG
SERVED_NAME=$SERVED_NAME
ALIAS=$ALIAS
SERVICE_NAME=$SERVICE_NAME
PORT=$API_PORT
GPUS=$GPUS
REPLICAS=$REPLICAS
PARALLEL=$PARALLEL
EOF
cat > "$STAGE/deploy-info" <<EOF
deployed_at=$DEPLOYED_AT
version=v$KIT_VERSION
strata=$STRATA_REPO@$STRATA_COMMIT
deploy_commit=$KIT_COMMIT
model=$MODEL_TITLE $SIZE
served_name=$SERVED_NAME
service=$SERVICE_NAME
replicas=$REPLICAS on GPUs $GPUS
port=$API_PORT
EOF
# The installer runs detached on the server, so a dropped SSH connection does not stop it.
cat > "$STAGE/start-install.sh" <<'EOF'
cd "$(dirname "$0")" && rm -f install.rc install.log
setsid nohup bash -c 'bash install-server.sh; echo $? > install.rc' > install.log 2>&1 < /dev/null &
echo $! > install.pid
EOF
# Shows the installer log until the model starts loading; from there the loader below takes over.
cat > "$STAGE/follow-log.sh" <<'EOF'
cd "$(dirname "$0")" || exit 1
pid=$(cat install.pid)
tail -n +1 -f --pid="$pid" install.log & t=$!
while kill -0 "$pid" 2>/dev/null && ! grep -q '^Waiting for the model' install.log; do sleep 1; done
sleep 1; kill "$t" 2>/dev/null; wait "$t" 2>/dev/null
true
EOF
# One probe for the loader: installer result, used RAM, memory on the serving GPUs, the service's last log line.
cat > "$STAGE/load-status.sh" <<'EOF'
cd "$(dirname "$0")" || exit 1
. ./strata.env
echo "RC=$(cat install.rc 2>/dev/null)"
kill -0 "$(cat install.pid 2>/dev/null)" 2>/dev/null && echo RUNNING=yes
awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {print "RAM=" int((t - a) / 1024) " " int(t / 1024)}' /proc/meminfo
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null \
  | awk -F', *' '{u += $1; t += $2} END {print "MEM=" u + 0 " " t + 0}'
journalctl -u "$SERVICE_NAME.service" -n 1 -o cat --no-pager 2>/dev/null | tr '\r' '\n' | tail -n 1 | cut -c 1-300 | sed 's/^/LAST=/'
true
EOF

COPYFILE_DISABLE=1 tar -C "$WORK" -czf - strata-kit \
  | rsh "$SUDO bash -c 'rm -rf $REMOTE_KIT && tar --warning=no-unknown-keyword -xzf - -C $(dirname "$REMOTE_KIT")'"
ok "комплект и исходный код Strata загружены в $REMOTE_KIT."

if [[ -n $CONFLICTS ]]; then
  for unit in $CONFLICTS; do rsh "$SUDO systemctl disable --now $(printf '%q' "$unit")"; done
  ok "остановлены и отключены: $(printf '%s' "$CONFLICTS" | tr '\n' ' ')"
fi

rsh "$SUDO bash $REMOTE_KIT/start-install.sh"
say '  Установка запущена на сервере. Первый раз она занимает от 30 минут до часа: Python, CUDA Toolkit, сборка движка,'
say "  около $DOWNLOAD_GB ГБ модели, её подготовка и запуск. Ctrl+C прерывает только показ, установка продолжится."
say "  Журнал на сервере: $REMOTE_KIT/install.log"
say ''
rsh "$SUDO bash $REMOTE_KIT/follow-log.sh" || true

# Strata keeps the API port closed until every replica has the model in RAM and on its GPU, so instead of raw health
# probes the user sees a loader: elapsed time, how full RAM and the GPUs already are, and the engine's last log line.
gib() { printf '%d,%d' $(($1 / 1024)) $(($1 * 10 / 1024 % 10)); }
bar() {
  local used=$1 total=$2 width=16 fill out='' i
  (( total > 0 )) || return 0
  fill=$(( used * width / total )); (( fill > width )) && fill=$width
  for (( i = 0; i < width; i++ )); do if (( i < fill )); then out+='█'; else out+='░'; fi; done
  printf '%s %s/%s ГиБ' "$out" "$(gib "$used")" "$(gib "$total")"
}
show_loader() {
  local spin=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 start=$SECONDS next=0 st k v el gpu='' ram='' last='' shown=''
  local L_RC='' L_RUNNING='' L_MEM='' L_RAM='' L_LAST=''
  say "  Загрузка модели в память и видеокарты (обычно 3-15 минут). Порт API откроется, когда модель будет готова."
  while :; do
    if (( SECONDS >= next )); then
      next=$((SECONDS + 3))
      if st=$(rsh "$SUDO bash $REMOTE_KIT/load-status.sh" 2>/dev/null); then
        L_RC='' L_RUNNING='' L_MEM='' L_RAM='' L_LAST=''
        while IFS='=' read -r k v; do
          case $k in RC|RUNNING|MEM|RAM|LAST) printf -v "L_$k" '%s' "$v";; esac
        done <<< "$st"
        [[ -n $L_RC || -z $L_RUNNING ]] && break
        # shellcheck disable=SC2086 # "used total" splits into two arguments
        gpu=$(bar ${L_MEM:-0 0}); ram=$(bar ${L_RAM:-0 0})
        last=$(printf '%s' "$L_LAST" | sed 's/^\[[^]]*\] *//' | cut -c 1-60)
      fi
      (( SECONDS - start < 2400 )) || break
    fi
    el=$((SECONDS - start))
    if [[ -t 1 ]]; then
      printf '\r\e[K  %s %d:%02d  видеокарты %s  память %s  %s' "${spin[i % 10]}" $((el / 60)) $((el % 60)) "$gpu" "$ram" "$last"
    elif [[ $last != "$shown" ]]; then
      say "  $((el / 60)):$(printf '%02d' $((el % 60)))  $last"; shown=$last
    fi
    i=$((i + 1)); sleep 0.25
  done
  [[ -t 1 ]] && printf '\r\e[K'
  el=$((SECONDS - start))
  if [[ $L_RC == 0 ]]; then ok "модель загружена за $((el / 60)) мин $((el % 60)) с."; fi
  return 0
}
RC=$(rsh "$SUDO cat $REMOTE_KIT/install.rc 2>/dev/null" || true)
if [[ -z $RC ]] && rsh "$SUDO grep -q '^Waiting for the model' $REMOTE_KIT/install.log" 2>/dev/null; then
  show_loader
  RC=$(rsh "$SUDO cat $REMOTE_KIT/install.rc 2>/dev/null" || true)
  [[ -z $RC || $RC == 0 ]] || rsh "$SUDO tail -n 40 $REMOTE_KIT/install.log" || true
fi
if [[ -z $RC ]]; then
  die "установка ещё идёт или прервана. Посмотреть журнал: ssh -p $SSH_PORT $TARGET tail -f $REMOTE_KIT/install.log"
fi
[[ $RC == 0 ]] || die "установка завершилась с кодом $RC. Журнал на сервере: $REMOTE_KIT/install.log, служба: journalctl -u $SERVICE_NAME."

# ---------- 7. Check from outside ----------

head_ '7. Проверка API снаружи'
API_KEY=$(rsh "$SUDO cat /root/strata-api.key")
code=$(curl -s -o /dev/null -w '%{http_code}' -m 15 "http://$HOST:$API_PORT/v1/models" || true)
keyed=$(curl -s -o /dev/null -w '%{http_code}' -m 15 -H "Authorization: Bearer $API_KEY" "http://$HOST:$API_PORT/v1/models" || true)
if [[ $keyed == 200 ]]; then
  ok "API отвечает: http://$HOST:$API_PORT/v1, модель $SERVED_NAME."
  if [[ $code == 401 ]]; then ok 'запрос без ключа отклоняется (HTTP 401).'; else warn "запрос без ключа вернул HTTP $code, ожидался 401."; fi
else
  warn "сервер готов изнутри, но снаружи http://$HOST:$API_PORT недоступен (HTTP ${keyed:-нет ответа}). Откройте порт $API_PORT в межсетевом экране сервера или облака."
fi
say "  API-ключ хранится на сервере в /root/strata-api.key."
if confirm 'Показать API-ключ в терминале?' y; then say "  $API_KEY"; fi
API_KEY=''
say ''
say "${G}Развёртывание завершено.${N} Запись о версии: /opt/strata/deploy-info на сервере (комплект v$KIT_VERSION, коммит $KIT_COMMIT, Strata $STRATA_SHORT, $DEPLOYED_AT)."
