#!/usr/bin/env bash
#
# setup-fuctura-labs.sh
#
# Ambiente padrão de laboratório da Fuctura.
# Ver README do repositório para instruções de uso.
#
set -euo pipefail

# Evita que apt/needrestart abram diálogos interativos ("quais serviços
# reiniciar?", etc.) — essencial pra rodar sem travar numa sessão sem
# terminal interativo.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a


# =====================================================================
# 0) ARGUMENTOS
# =====================================================================

FORCE=false

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        *)
            echo "Argumento desconhecido: $arg"
            echo "Uso: sudo ./setup-fuctura-labs.sh [--force]"
            exit 1
            ;;
    esac
done


# =====================================================================
# 1) VERIFICAÇÃO DE ROOT
# =====================================================================

if [[ "$EUID" -ne 0 ]]; then
    echo "ERRO: execute este script com sudo."
    echo
    echo "Exemplo:"
    echo "  sudo ./setup-fuctura-labs.sh"
    exit 1
fi


# =====================================================================
# 2) MARCA DE PROVISIONAMENTO (idempotência)
# =====================================================================
#
# Evita reinstalar tudo do zero em máquinas que já rodaram o script.
# Use --force para reprovisionar mesmo assim.
# ---------------------------------------------------------------------

PROVISIONED_MARKER="/etc/fuctura-labs-provisioned"

if [[ -f "$PROVISIONED_MARKER" && "$FORCE" == false ]]; then
    echo "Esta máquina já foi provisionada em $(cat "$PROVISIONED_MARKER")."
    echo "Rode com --force se quiser reprovisionar mesmo assim."
    exit 0
fi


# =====================================================================
# 3) IDENTIFICAÇÃO DO SISTEMA OPERACIONAL
# =====================================================================

source /etc/os-release

echo
echo "=================================================================="
echo "           AMBIENTE FUCTURA - INSTALAÇÃO"
echo "=================================================================="
echo
echo "Sistema detectado: ${PRETTY_NAME:-$ID}"
echo

case "$ID" in
    ubuntu)
        if [[ "${VERSION_ID:-}" != "24.04" ]]; then
            echo "ERRO: esta versão do Ubuntu não é suportada."
            echo "Sistemas suportados: Ubuntu 24.04 LTS, Linux Mint 22.x"
            exit 1
        fi
        echo "✓ Ubuntu 24.04 LTS reconhecido."
        ;;
    linuxmint)
        if [[ "${VERSION_ID:-}" != 22* ]]; then
            echo "ERRO: esta versão do Linux Mint não é suportada."
            echo "Sistemas suportados: Ubuntu 24.04 LTS, Linux Mint 22.x"
            exit 1
        fi
        echo "✓ Linux Mint 22.x reconhecido."
        ;;
    *)
        echo "ERRO: sistema operacional não suportado."
        echo "Sistemas suportados: Ubuntu 24.04 LTS, Linux Mint 22.x"
        exit 1
        ;;
esac


# =====================================================================
# 4) USUÁRIO ALUNO
# =====================================================================
#
# Precisa vir ANTES de qualquer variável que dependa de $REAL_HOME (ex.:
# caminho de dados do DBeaver). Na versão anterior essa ordem estava
# invertida e causava "unbound variable" com set -u logo no início.
# ---------------------------------------------------------------------

REAL_USER="aluno"

if ! id "$REAL_USER" >/dev/null 2>&1; then
    echo "ERRO: o usuário '$REAL_USER' não existe."
    echo "Crie o usuário antes de executar o instalador:"
    echo "  sudo adduser $REAL_USER"
    exit 1
fi

REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

if [[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]]; then
    echo "ERRO: não foi possível localizar o HOME de '$REAL_USER'."
    exit 1
fi

echo
echo "Usuário do laboratório : $REAL_USER"
echo "HOME                   : $REAL_HOME"
echo


# =====================================================================
# 5) CONFIGURAÇÕES GERAIS
# =====================================================================
#
# Senhas mantidas propositalmente simples/previsíveis (aluno/aluno,
# postgres/postgres) — decisão pedagógica, fora do escopo desta revisão.
# ---------------------------------------------------------------------

REAL_USER_PASSWORD="aluno"

PG_USER="postgres"
PG_PASSWORD="postgres"
PG_PORT="5432"
PG_DEFAULT_DATABASE="postgres"

DBEAVER_CONNECTION_NAME="PostgreSQL - Local"
DBEAVER_DATA_DIR="$REAL_HOME/.local/share/DBeaverData"
DBEAVER_WORKSPACE="$DBEAVER_DATA_DIR/workspace6"
DBEAVER_GENERAL="$DBEAVER_WORKSPACE/General"
DBEAVER_DBEAVER_DIR="$DBEAVER_GENERAL/.dbeaver"

# Dia/hora do reset semanal do perfil aluno (formato OnCalendar do systemd).
RESET_SCHEDULE="Sun *-*-* 23:30:00"

SETTINGS_DIR="$REAL_HOME/.config/Code/User"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"


# =====================================================================
# 6) ESPAÇO EM DISCO
# =====================================================================

MIN_FREE_GB=8
AVAILABLE_GB="$(df --output=avail -BG / | tail -n1 | tr -dc '0-9')"

if (( AVAILABLE_GB < MIN_FREE_GB )); then
    echo "ERRO: espaço livre insuficiente em / (${AVAILABLE_GB} GB disponíveis,"
    echo "mínimo recomendado: ${MIN_FREE_GB} GB para JDK + Node + VS Code + DBeaver)."
    exit 1
fi

echo "✓ Espaço em disco: ${AVAILABLE_GB} GB disponíveis."
echo


# =====================================================================
# 7) REPOSITÓRIOS DE TERCEIROS
# =====================================================================
#
# Chaves/repos são adicionados aqui; um único "apt-get update" cobre
# todos eles logo abaixo, em vez de um update por repositório.
# ---------------------------------------------------------------------

echo "==> Configurando repositórios de terceiros..."

# --- Adoptium / Eclipse Temurin --------------------------------------
rm -f /etc/apt/trusted.gpg.d/adoptium.gpg
wget -qO- https://packages.adoptium.net/artifactory/api/gpg/key/public \
    | gpg --dearmor > /etc/apt/trusted.gpg.d/adoptium.gpg

CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-noble}")"
echo "deb https://packages.adoptium.net/artifactory/deb ${CODENAME} main" \
    > /etc/apt/sources.list.d/adoptium.list

# --- VS Code ----------------------------------------------------------
# URL correta é /keys/microsoft.asc (a versão anterior tinha o /keys/
# faltando e baixava um 404).
wget -qO- https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor > /tmp/packages.microsoft.gpg
install -D -o root -g root -m 644 \
    /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
rm -f /tmp/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
    > /etc/apt/sources.list.d/vscode.list

# --- DBeaver ------------------------------------------------------------
wget -qO- https://dbeaver.io/debs/dbeaver.gpg.key \
    | gpg --dearmor > /usr/share/keyrings/dbeaver.gpg.key
echo "deb [signed-by=/usr/share/keyrings/dbeaver.gpg.key] https://dbeaver.io/debs/dbeaver-ce /" \
    > /etc/apt/sources.list.d/dbeaver.list

echo "==> Atualizando índices dos pacotes..."
apt-get update -y


# =====================================================================
# 8) FERRAMENTAS BÁSICAS
# =====================================================================

echo "==> Instalando ferramentas básicas..."
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gpg git unzip zip \
    build-essential software-properties-common


# =====================================================================
# 9) JAVA 26 - ECLIPSE TEMURIN
# =====================================================================

echo "==> Instalando Java 26 - Eclipse Temurin..."
apt-get install -y --no-install-recommends temurin-26-jdk

JAVA26_BIN="$(find /usr/lib/jvm -maxdepth 1 -type d -name 'temurin-26-jdk-*' | head -n1)"

if [[ -z "$JAVA26_BIN" ]]; then
    echo "ERRO: JDK 26 não foi localizado após a instalação."
    exit 1
fi

update-alternatives --install /usr/bin/java java "$JAVA26_BIN/bin/java" 2600
update-alternatives --install /usr/bin/javac javac "$JAVA26_BIN/bin/javac" 2600
update-alternatives --set java "$JAVA26_BIN/bin/java"
update-alternatives --set javac "$JAVA26_BIN/bin/javac"

cat > /etc/profile.d/java_home.sh <<EOF
export JAVA_HOME="$JAVA26_BIN"
EOF
chmod 644 /etc/profile.d/java_home.sh


# =====================================================================
# 10) MAVEN
# =====================================================================

echo "==> Instalando Maven..."
apt-get install -y --no-install-recommends maven


# =====================================================================
# 11) POSTGRESQL
# =====================================================================

echo "==> Instalando PostgreSQL..."
apt-get install -y --no-install-recommends postgresql postgresql-contrib
systemctl enable --now postgresql

echo "==> Configurando credencial de aula do PostgreSQL..."
sudo -u postgres psql -c "ALTER USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}';"

if ! sudo -u postgres psql -c "SELECT version();" >/dev/null; then
    echo "ERRO: PostgreSQL foi instalado, mas não respondeu."
    exit 1
fi
echo "✓ PostgreSQL está funcionando."


# =====================================================================
# 12) NODE.JS 24 LTS + ANGULAR CLI
# =====================================================================
#
# O script de setup do nodesource já faz seu próprio "apt-get update"
# internamente ao adicionar o repositório, por isso não repetimos aqui.
# ---------------------------------------------------------------------

echo "==> Instalando Node.js 24 LTS..."
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y --no-install-recommends nodejs

echo "==> Instalando Angular CLI..."
npm install -g @angular/cli


# =====================================================================
# 13) PYTHON + DJANGO
# =====================================================================

echo "==> Instalando Python, pip, venv e Django..."
apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv python3-django


# =====================================================================
# 14) VS CODE
# =====================================================================

echo "==> Instalando VS Code..."
apt-get install -y --no-install-recommends code


# =====================================================================
# 15) EXTENSÕES DO VS CODE
# =====================================================================

echo "==> Instalando extensões do VS Code..."

EXTENSIONS=(
    vscjava.vscode-java-pack
    vmware.vscode-boot-dev-pack
    Angular.ng-template
    ms-python.python
    ms-ossdata.vscode-pgsql
    formulahendry.code-runner
)

FAILED_EXTENSIONS=()

for ext in "${EXTENSIONS[@]}"; do
    echo "    Instalando: $ext"
    if ! sudo -u "$REAL_USER" env HOME="$REAL_HOME" \
        code --install-extension "$ext" --force; then
        echo "    ATENÇÃO: falha ao instalar $ext"
        FAILED_EXTENSIONS+=("$ext")
    fi
done


# =====================================================================
# 16) CODE RUNNER
# =====================================================================

echo "==> Configurando Code Runner..."

mkdir -p "$SETTINGS_DIR"
chown "$REAL_USER:$REAL_USER" "$SETTINGS_DIR"

sudo -u "$REAL_USER" env HOME="$REAL_HOME" python3 - "$SETTINGS_FILE" <<'PYEOF'
import json
import os
import sys

path = sys.argv[1]

if os.path.exists(path):
    try:
        with open(path, "r", encoding="utf-8") as f:
            settings = json.load(f)
    except (json.JSONDecodeError, OSError):
        settings = {}
else:
    settings = {}

settings.setdefault("code-runner.executorMap", {})
settings["code-runner.executorMap"]["java"] = "cd $dir && java $fileName"
settings["code-runner.executorMap"]["python"] = "python3 -u $fileName"
settings["code-runner.runInTerminal"] = True
settings["code-runner.saveFileBeforeRun"] = True
settings["code-runner.clearPreviousOutput"] = True

with open(path, "w", encoding="utf-8") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYEOF

chown "$REAL_USER:$REAL_USER" "$SETTINGS_FILE"


# =====================================================================
# 17) DBEAVER COMMUNITY
# =====================================================================

echo "==> Instalando DBeaver Community..."
apt-get install -y --no-install-recommends dbeaver-ce

echo "==> Configurando conexão PostgreSQL no DBeaver..."
mkdir -p "$DBEAVER_DBEAVER_DIR"

cat > "$DBEAVER_DBEAVER_DIR/data-sources.json" <<EOF
{
  "folders": {},
  "connections": {
    "postgresql-fuctura-local": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "${DBEAVER_CONNECTION_NAME}",
      "save-password": true,
      "read-only": false,
      "configuration": {
        "host": "localhost",
        "port": "${PG_PORT}",
        "database": "${PG_DEFAULT_DATABASE}",
        "url": "jdbc:postgresql://localhost:${PG_PORT}/${PG_DEFAULT_DATABASE}",
        "configurationType": "MANUAL",
        "type": "dev",
        "auth-model": "native",
        "auth-properties": {
          "userName": "${PG_USER}",
          "userPassword": "${PG_PASSWORD}"
        }
      }
    }
  }
}
EOF

chown -R "$REAL_USER:$REAL_USER" "$DBEAVER_DATA_DIR"
chmod 700 "$DBEAVER_DATA_DIR" "$DBEAVER_WORKSPACE" "$DBEAVER_GENERAL" "$DBEAVER_DBEAVER_DIR"
chmod 600 "$DBEAVER_DBEAVER_DIR/data-sources.json"

echo "==> Inicializando workspace do DBeaver..."

# Em vez de um "sleep 12" fixo, espera até o DBeaver criar sua própria
# pasta de metadados no workspace (sinal de que já inicializou) ou até
# estourar o timeout — o que vier primeiro. É uma heurística: se a
# pasta .metadata não existir no seu DBeaver, ajuste o marcador abaixo.
sudo -u "$REAL_USER" env HOME="$REAL_HOME" \
    dbeaver -data "$DBEAVER_WORKSPACE" -nosplash \
    >/tmp/dbeaver-fuctura-init.log 2>&1 &
DBEAVER_PID=$!

DBEAVER_TIMEOUT=45
DBEAVER_ELAPSED=0
DBEAVER_METADATA_MARKER="$DBEAVER_WORKSPACE/.metadata"

while [[ ! -d "$DBEAVER_METADATA_MARKER" && $DBEAVER_ELAPSED -lt $DBEAVER_TIMEOUT ]]; do
    sleep 2
    DBEAVER_ELAPSED=$((DBEAVER_ELAPSED + 2))
done

if [[ -d "$DBEAVER_METADATA_MARKER" ]]; then
    echo "✓ Workspace do DBeaver inicializado (${DBEAVER_ELAPSED}s)."
else
    echo "AVISO: timeout de ${DBEAVER_TIMEOUT}s esperando o DBeaver inicializar o workspace."
    echo "       A conexão pré-configurada deve funcionar mesmo assim na primeira abertura pelo aluno."
fi

kill "$DBEAVER_PID" 2>/dev/null || true
sleep 2


# =====================================================================
# 18) /etc/skel
# =====================================================================

echo "==> Preparando /etc/skel..."

if [[ -d "$REAL_HOME/.vscode/extensions" ]]; then
    rm -rf /etc/skel/.vscode
    mkdir -p /etc/skel/.vscode
    cp -a "$REAL_HOME/.vscode/extensions" /etc/skel/.vscode/
fi

if [[ -f "$SETTINGS_FILE" ]]; then
    mkdir -p /etc/skel/.config/Code/User
    cp "$SETTINGS_FILE" /etc/skel/.config/Code/User/settings.json
fi

if [[ -d "$DBEAVER_DATA_DIR" ]]; then
    rm -rf /etc/skel/.local/share/DBeaverData
    mkdir -p /etc/skel/.local/share
    cp -a "$DBEAVER_DATA_DIR" /etc/skel/.local/share/
fi

chown -R root:root /etc/skel/.vscode 2>/dev/null || true
chown -R root:root /etc/skel/.config 2>/dev/null || true
chown -R root:root /etc/skel/.local 2>/dev/null || true


# =====================================================================
# 19) RESET SEMANAL
# =====================================================================
#
# Usuário e senhas são injetados via sed logo após o heredoc, para que
# a seção 5 continue sendo a única fonte da verdade — evita que
# reset-aluno.sh fique com valores desatualizados se as variáveis lá em
# cima mudarem e alguém esquecer de atualizar aqui também.
# ---------------------------------------------------------------------

echo "==> Criando script de reset..."

cat > /usr/local/sbin/reset-aluno.sh <<'RESETEOF'
#!/usr/bin/env bash
set -euo pipefail

USER_TO_RESET="__REAL_USER__"
USER_PASS="__REAL_USER_PASSWORD__"
HOME_DIR="/home/$USER_TO_RESET"
LOG="/var/log/reset-aluno.log"
PG_SUPERUSER_PASSWORD="__PG_PASSWORD__"

log() {
    echo "$(date '+%F %T') - $1" >> "$LOG"
}

log "============================================================"
log "Iniciando reset do perfil $USER_TO_RESET"

log "Encerrando processos do usuário."
loginctl terminate-user "$USER_TO_RESET" 2>/dev/null || true
pkill -KILL -u "$USER_TO_RESET" 2>/dev/null || true
sleep 2

log "Removendo $HOME_DIR."
rm -rf "${HOME_DIR:?}"

log "Recriando perfil a partir de /etc/skel."
mkdir -p "$HOME_DIR"
cp -a /etc/skel/. "$HOME_DIR/"

chown -R "$USER_TO_RESET:$USER_TO_RESET" "$HOME_DIR"
chmod 750 "$HOME_DIR"

log "Restaurando senha do usuário."
echo "$USER_TO_RESET:$USER_PASS" | chpasswd

log "Iniciando reset do PostgreSQL."

PROTECTED_DBS=("postgres" "template0" "template1")

DBS="$(sudo -u postgres psql -tAc \
    "SELECT datname FROM pg_database WHERE datistemplate = false;")"

for db in $DBS; do
    protected=false
    for protected_db in "${PROTECTED_DBS[@]}"; do
        [[ "$db" == "$protected_db" ]] && protected=true && break
    done

    if [[ "$protected" == false ]]; then
        log "Apagando banco: $db"
        sudo -u postgres psql -c \
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db';" \
            >/dev/null 2>&1 || true
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$db\";" >> "$LOG" 2>&1
    fi
done

log "Restaurando senha do PostgreSQL."
sudo -u postgres psql -c \
    "ALTER USER postgres WITH PASSWORD '$PG_SUPERUSER_PASSWORD';" >> "$LOG" 2>&1

log "Reset concluído."
log "============================================================"
exit 0
RESETEOF

sed -i \
    -e "s#__REAL_USER__#${REAL_USER}#g" \
    -e "s#__REAL_USER_PASSWORD__#${REAL_USER_PASSWORD}#g" \
    -e "s#__PG_PASSWORD__#${PG_PASSWORD}#g" \
    /usr/local/sbin/reset-aluno.sh

chmod 700 /usr/local/sbin/reset-aluno.sh


# =====================================================================
# 20) SYSTEMD SERVICE + TIMER
# =====================================================================

echo "==> Criando serviço e timer systemd..."

cat > /etc/systemd/system/reset-aluno.service <<'SERVICEEOF'
[Unit]
Description=Reset do ambiente do aluno Fuctura
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reset-aluno.sh
SERVICEEOF

cat > /etc/systemd/system/reset-aluno.timer <<'TIMEREOF'
[Unit]
Description=Reset semanal do ambiente Fuctura

[Timer]
OnCalendar=__RESET_SCHEDULE__
Persistent=true
Unit=reset-aluno.service

[Install]
WantedBy=timers.target
TIMEREOF

sed -i "s#__RESET_SCHEDULE__#${RESET_SCHEDULE}#g" /etc/systemd/system/reset-aluno.timer

systemctl daemon-reload
systemctl enable --now reset-aluno.timer


# =====================================================================
# 21) MARCA DE PROVISIONAMENTO
# =====================================================================

date '+%F %T' > "$PROVISIONED_MARKER"


# =====================================================================
# 22) DIAGNÓSTICO FINAL
# =====================================================================

echo
echo
echo "=================================================================="
echo "                  DIAGNÓSTICO FINAL"
echo "=================================================================="
echo

echo "[SISTEMA]"
echo "✓ $PRETTY_NAME"
echo

echo "[JAVA]"
if java --version >/dev/null 2>&1; then
    echo "✓ $(java --version 2>&1 | head -n1)"
else
    echo "✗ Java não está funcionando."
fi
if javac --version >/dev/null 2>&1; then
    echo "✓ $(javac --version)"
else
    echo "✗ javac não está funcionando."
fi
echo

echo "[MAVEN]"
if mvn --version >/dev/null 2>&1; then
    echo "✓ $(mvn --version 2>&1 | head -n1)"
else
    echo "✗ Maven não está funcionando."
fi
echo

echo "[NODE]"
if node --version >/dev/null 2>&1; then
    echo "✓ Node $(node --version)"
else
    echo "✗ Node não está funcionando."
fi
if npm --version >/dev/null 2>&1; then
    echo "✓ npm $(npm --version)"
else
    echo "✗ npm não está funcionando."
fi
if ng version >/dev/null 2>&1; then
    echo "✓ Angular CLI disponível."
else
    echo "✗ Angular CLI não está funcionando."
fi
echo

echo "[PYTHON]"
echo "✓ $(python3 --version)"
if python3 -m pip --version >/dev/null 2>&1; then
    echo "✓ pip disponível."
else
    echo "✗ pip não está disponível."
fi
if python3 -m django --version >/dev/null 2>&1; then
    echo "✓ Django $(python3 -m django --version)"
else
    echo "✗ Django não está funcionando."
fi
echo

echo "[POSTGRESQL]"
if systemctl is-active --quiet postgresql; then
    echo "✓ Serviço PostgreSQL ativo."
else
    echo "✗ Serviço PostgreSQL não está ativo."
fi
if sudo -u postgres psql -c "SELECT 1;" >/dev/null 2>&1; then
    echo "✓ PostgreSQL responde."
else
    echo "✗ PostgreSQL não respondeu."
fi
echo

echo "[DBEAVER]"
if command -v dbeaver >/dev/null 2>&1; then
    echo "✓ DBeaver instalado."
else
    echo "✗ DBeaver não foi encontrado."
fi
if [[ -f "$DBEAVER_DBEAVER_DIR/data-sources.json" ]]; then
    echo "✓ Conexão PostgreSQL pré-configurada."
else
    echo "✗ Configuração do DBeaver não encontrada."
fi
echo

echo "[VS CODE]"
if command -v code >/dev/null 2>&1; then
    echo "✓ $(code --version | head -n1)"
else
    echo "✗ VS Code não foi encontrado."
fi
echo

echo "[EXTENSÕES DO VS CODE]"
for ext in "${EXTENSIONS[@]}"; do
    if sudo -u "$REAL_USER" env HOME="$REAL_HOME" code --list-extensions 2>/dev/null | grep -Fxq "$ext"; then
        echo "✓ $ext"
    else
        echo "✗ $ext"
    fi
done
if (( ${#FAILED_EXTENSIONS[@]} > 0 )); then
    echo
    echo "AVISO: falharam durante a instalação: ${FAILED_EXTENSIONS[*]}"
fi
echo

echo "[RESET SEMANAL]"
if systemctl is-enabled --quiet reset-aluno.timer; then
    echo "✓ Timer habilitado."
else
    echo "✗ Timer não está habilitado."
fi
NEXT_RESET="$(systemctl show reset-aluno.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
if [[ -n "$NEXT_RESET" ]]; then
    echo "Próximo reset: $NEXT_RESET"
fi
echo

echo "=================================================================="
echo "                 AMBIENTE FUCTURA PREPARADO"
echo "=================================================================="
echo
echo "Usuário de aula : $REAL_USER"
echo "Sistema         : $PRETTY_NAME"
echo
echo "Reset semanal   : $RESET_SCHEDULE"
echo
echo "Reprovisionar esta máquina no futuro: sudo ./setup-fuctura-labs.sh --force"
echo "=================================================================="
