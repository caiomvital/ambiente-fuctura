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


# ---------------------------------------------------------------------
# LOG CENTRALIZADO
#
# Toda a saída do script (stdout e stderr) passa a ir simultaneamente
# pro terminal e pra este arquivo. Útil pra diagnosticar à distância
# uma máquina que falhou no meio da instalação: "cat" ou "tail" nesse
# log dá o histórico completo, sem precisar reproduzir o problema.
# ---------------------------------------------------------------------

INSTALL_LOG="/var/log/fuctura-labs-install.log"
exec > >(tee -a "$INSTALL_LOG") 2>&1


# =====================================================================
# 2) MARCA DE PROVISIONAMENTO (idempotência)
# =====================================================================
#
# Evita reinstalar tudo do zero em máquinas que já rodaram o script.
#
# IMPORTANTE: isso é só um "já rodei antes, não rodo de novo" — o script
# NÃO verifica se algo quebrou ou foi desinstalado desde então (ex.:
# alguém removeu o DBeaver). Se precisar checar/reparar uma máquina,
# rode com --force.
#
# --force não é um "modo de verificação": ele REPROVISIONA a máquina
# por completo — reaplica extensões, configurações, DBeaver, /etc/skel,
# reset semanal e credenciais do zero.
# ---------------------------------------------------------------------

PROVISIONED_MARKER="/etc/fuctura-labs-provisioned"

if [[ -f "$PROVISIONED_MARKER" && "$FORCE" == false ]]; then
    echo "Esta máquina já foi provisionada em $(cat "$PROVISIONED_MARKER")."
    echo "O script não faz nenhuma verificação ou reparo automático — ele só"
    echo "pula a instalação porque já rodou aqui antes."
    echo "Use --force para reprovisionar a máquina por completo."
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

OS_UNTESTED=false
TESTED_UBUNTU_VERSIONS=("24.04" "22.04" "20.04")

case "$ID" in
    ubuntu)
        if [[ "${VERSION_ID:-}" =~ ^([0-9]{2})\.04$ ]]; then
            LTS_YEAR="${BASH_REMATCH[1]}"
            if (( LTS_YEAR % 2 != 0 )); then
                echo "ERRO: Ubuntu ${VERSION_ID} não é uma versão LTS."
                echo "Sistemas suportados: qualquer Ubuntu LTS (AA.04 de ano par), Linux Mint 22.x"
                exit 1
            fi

            IS_TESTED=false
            for v in "${TESTED_UBUNTU_VERSIONS[@]}"; do
                [[ "$v" == "${VERSION_ID}" ]] && IS_TESTED=true && break
            done

            if [[ "$IS_TESTED" == true ]]; then
                echo "✓ Ubuntu ${VERSION_ID} LTS reconhecido."
            else
                OS_UNTESTED=true
                echo "⚠ Ubuntu ${VERSION_ID} LTS reconhecido, mas ainda não testado com"
                echo "  este script (testados até agora: ${TESTED_UBUNTU_VERSIONS[*]})."
                echo "  Prosseguindo mesmo assim — confira o diagnóstico final com atenção."
            fi
        else
            echo "ERRO: esta versão do Ubuntu não é suportada (só LTS, formato AA.04)."
            echo "Sistemas suportados: qualquer Ubuntu LTS (AA.04 de ano par), Linux Mint 22.x"
            exit 1
        fi
        ;;
    linuxmint)
        if [[ "${VERSION_ID:-}" != 22* ]]; then
            echo "ERRO: esta versão do Linux Mint não é suportada."
            echo "Sistemas suportados: qualquer Ubuntu LTS (AA.04 de ano par), Linux Mint 22.x"
            exit 1
        fi
        echo "✓ Linux Mint 22.x reconhecido."
        ;;
    *)
        echo "ERRO: sistema operacional não suportado."
        echo "Sistemas suportados: qualquer Ubuntu LTS (AA.04 de ano par), Linux Mint 22.x"
        exit 1
        ;;
esac

# Ubuntu 20.04 só tem PostgreSQL 12 no repositório padrão, que não
# suporta "DROP DATABASE ... WITH (FORCE)" usado no reset semanal (só
# existe a partir do PG 13). Por isso adicionamos o repositório oficial
# da PostgreSQL (PGDG) mais abaixo, garantindo uma versão atual em
# qualquer uma das distros suportadas, em vez de depender do que cada
# base trouxe por padrão.


# =====================================================================
# 4) USUÁRIO ALUNO
# =====================================================================
#
# Precisa vir ANTES de qualquer variável que dependa de $REAL_HOME (ex.:
# caminho de dados do DBeaver). Na versão anterior essa ordem estava
# invertida e causava "unbound variable" com set -u logo no início.
#
# Senha mantida propositalmente simples/previsível (aluno/aluno) —
# decisão pedagógica, fora do escopo desta revisão.
# ---------------------------------------------------------------------

REAL_USER="aluno"
REAL_USER_PASSWORD="aluno"

if ! id "$REAL_USER" >/dev/null 2>&1; then
    echo "Usuário '$REAL_USER' não existe — criando..."

    # useradd (e não adduser) porque é não-interativo por natureza; o
    # adduser do Debian/Ubuntu pergunta nome completo, telefone etc.
    # mesmo com DEBIAN_FRONTEND=noninteractive, já que isso é
    # comportamento do próprio adduser, não do apt.
    useradd -m -s /bin/bash "$REAL_USER"
    echo "✓ Usuário '$REAL_USER' criado."
fi

# Fora do "if" de propósito: se o usuário já existir (ex.: rodando com
# --force numa máquina já provisionada), garante mesmo assim que a
# senha seja a definida aqui — senão --force não reprovisiona de fato
# essa credencial se alguém tiver trocado a senha manualmente.
echo "$REAL_USER:$REAL_USER_PASSWORD" | chpasswd

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
# REAL_USER e REAL_USER_PASSWORD já foram definidas na seção 4.
# Senha do PostgreSQL mantida propositalmente simples/previsível
# (postgres/postgres) — decisão pedagógica, fora do escopo desta revisão.
# ---------------------------------------------------------------------

PG_USER="postgres"
PG_PASSWORD="postgres"
PG_PORT="5432"
PG_DEFAULT_DATABASE="postgres"

# Setada para false na seção 17 se o DBeaver não preservar a conexão
# pré-configurada após a primeira inicialização — vira aviso no
# diagnóstico final, não aborta o provisionamento.
DBEAVER_CONNECTION_OK=true

DBEAVER_CONNECTION_NAME="PostgreSQL - Local"
DBEAVER_DATA_DIR="$REAL_HOME/.local/share/DBeaverData"
DBEAVER_WORKSPACE="$DBEAVER_DATA_DIR/workspace6"
DBEAVER_GENERAL="$DBEAVER_WORKSPACE/General"
DBEAVER_DBEAVER_DIR="$DBEAVER_GENERAL/.dbeaver"

# Reset principal: domingo às 22:30, fora do expediente e antes da
# semana de aula começar.
#
# Reset de recuperação: seg/qua/sex às 15h — só executa DE FATO se o
# principal não tiver rodado recentemente (a máquina estava desligada
# no domingo). Isso evita usar "Persistent=true" no timer, que faria o
# reset disparar de surpresa assim que a máquina fosse ligada a
# qualquer hora — inclusive com alguém já trabalhando no perfil
# principal. Com dois horários fixos, o reset só acontece nesses
# momentos previsíveis, nunca "no boot".
RESET_SCHEDULE_PRIMARY="Sun *-*-* 22:30:00"
RESET_SCHEDULE_CATCHUP="Mon,Wed,Fri *-*-* 15:00:00"

# Se o último reset bem-sucedido tiver menos que isso, a recuperação
# entende que o principal já rodou essa semana e não faz nada.
CATCHUP_MAX_AGE_DAYS=4

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

# O repositório da Adoptium só conhece codenames Ubuntu (noble, jammy...).
# No Linux Mint, VERSION_CODENAME é o nome próprio do Mint (ex.: "wilma"),
# não a base Ubuntu — por isso usamos UBUNTU_CODENAME nesse caso.
if [[ "$ID" == "linuxmint" ]]; then
    CODENAME="${UBUNTU_CODENAME:-noble}"
else
    CODENAME="${VERSION_CODENAME:-noble}"
fi
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

# --- PostgreSQL (PGDG) --------------------------------------------------
# Repositório oficial da PostgreSQL — garante uma versão atual (com
# suporte a "DROP DATABASE ... WITH (FORCE)", usado no reset semanal)
# em qualquer uma das distros suportadas, em vez de depender da versão
# que cada base traz por padrão (Ubuntu 20.04, por exemplo, só tem
# PostgreSQL 12 no repositório padrão). Usa o mesmo $CODENAME já
# resolvido acima (com o ajuste de Mint incluso).
#
# Ubuntu 20.04 (focal) é EOL e o PGDG removeu os pacotes do repositório
# principal em jul/2025 — o índice ainda existe lá (por isso o
# apt-get update não acusa erro), mas os .deb de verdade só existem no
# repositório de arquivo. Por isso o host muda nesse caso específico.
PGDG_HOST="apt.postgresql.org"
if [[ "$CODENAME" == "focal" ]]; then
    PGDG_HOST="apt-archive.postgresql.org"
fi

wget -qO- https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor > /usr/share/keyrings/postgresql.gpg
echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://${PGDG_HOST}/pub/repos/apt ${CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

echo "==> Atualizando índices dos pacotes..."
# Não usamos "set -e" puro aqui de propósito: se a máquina já tiver
# algum repositório de terceiros pré-existente e quebrado (chave GPG
# faltando, 404 etc.) que não tem nada a ver com o que este script
# instala, isso não deveria derrubar o provisionamento inteiro. Os
# passos seguintes já têm suas próprias checagens (ex.: abortamos se o
# JDK 26 não aparecer depois da instalação) — essas é que decidem se um
# problema é real pra gente.
if ! apt-get update -y; then
    echo "AVISO: 'apt-get update' encontrou erro em pelo menos um repositório."
    echo "       Prosseguindo mesmo assim — se isso afetar algo que este"
    echo "       script realmente precisa instalar, o passo específico vai"
    echo "       falhar de forma clara logo em seguida."
fi


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

# A existência do .metadata só prova que o DBeaver rodou — não que ele
# preservou a conexão que escrevemos em data-sources.json (ele reescreve
# esse arquivo ao migrar a senha pro armazenamento protegido próprio).
# Confirma que os dados essenciais da conexão continuam lá.
if [[ -f "$DBEAVER_DBEAVER_DIR/data-sources.json" ]] \
    && grep -q "${DBEAVER_CONNECTION_NAME}" "$DBEAVER_DBEAVER_DIR/data-sources.json" \
    && grep -q "localhost" "$DBEAVER_DBEAVER_DIR/data-sources.json" \
    && grep -q "${PG_USER}" "$DBEAVER_DBEAVER_DIR/data-sources.json"; then
    echo "✓ Conexão '${DBEAVER_CONNECTION_NAME}' confirmada em data-sources.json."
else
    DBEAVER_CONNECTION_OK=false
    echo "AVISO: a conexão pré-configurada do DBeaver não foi encontrada após a"
    echo "       inicialização — confira manualmente antes de liberar a máquina."
fi


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

if [[ -f "$DBEAVER_DBEAVER_DIR/data-sources.json" ]]; then
    # Só o arquivo de conexão, não o workspace inteiro (.metadata, cache,
    # secure storage). Copiar o DBeaverData inteiro faria o reset semanal
    # herdar estado interno do DBeaver amarrado à versão/execução do
    # momento da instalação, em vez de uma configuração limpa — o DBeaver
    # recria .metadata e o resto sozinho na primeira abertura do aluno.
    SKEL_DBEAVER_DIR="/etc/skel/.local/share/DBeaverData/workspace6/General/.dbeaver"
    rm -rf /etc/skel/.local/share/DBeaverData
    mkdir -p "$SKEL_DBEAVER_DIR"
    cp "$DBEAVER_DBEAVER_DIR/data-sources.json" "$SKEL_DBEAVER_DIR/"
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

# Timestamp do último reset bem-sucedido — o script de recuperação
# (reset-aluno-catchup.sh) usa isso pra decidir se precisa agir ou se o
# reset principal já rodou essa semana. Fica em /var/lib porque precisa
# sobreviver a reboot (diferente de /run ou /tmp).
RESET_MARKER="/var/lib/fuctura-labs/last-reset"
mkdir -p "$(dirname "$RESET_MARKER")"

log() {
    echo "$(date '+%F %T') - $1" >> "$LOG"
}

log "============================================================"

if ! id "$USER_TO_RESET" >/dev/null 2>&1; then
    log "ERRO: usuário '$USER_TO_RESET' não existe — abortando reset."
    exit 1
fi

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
        # WITH (FORCE) (PostgreSQL 13+) derruba conexões ativas e apaga o
        # banco num único comando atômico — evita a janela entre
        # terminar conexões e o DROP em que uma nova sessão poderia
        # abrir e fazer o DROP falhar.
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE);" >> "$LOG" 2>&1
    fi
done

log "Restaurando senha do PostgreSQL."
sudo -u postgres psql -c \
    "ALTER USER postgres WITH PASSWORD '$PG_SUPERUSER_PASSWORD';" >> "$LOG" 2>&1

echo "$(date +%s)" > "$RESET_MARKER"

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

echo "==> Criando script de recuperação do reset..."

cat > /usr/local/sbin/reset-aluno-catchup.sh <<'CATCHUPEOF'
#!/usr/bin/env bash
set -euo pipefail

RESET_MARKER="/var/lib/fuctura-labs/last-reset"
RESET_SCRIPT="/usr/local/sbin/reset-aluno.sh"
LOG="/var/log/reset-aluno.log"
MAX_AGE_SECONDS=$(( __CATCHUP_MAX_AGE_DAYS__ * 24 * 60 * 60 ))

log() {
    echo "$(date '+%F %T') - $1" >> "$LOG"
}

NOW="$(date +%s)"

if [[ -f "$RESET_MARKER" ]]; then
    LAST="$(cat "$RESET_MARKER")"
    AGE=$(( NOW - LAST ))
    if (( AGE < MAX_AGE_SECONDS )); then
        log "Catch-up: último reset há $(( AGE / 3600 ))h — dentro do prazo, pulando."
        exit 0
    fi
fi

log "Catch-up: reset principal não confirmado recentemente — executando agora."
"$RESET_SCRIPT"
CATCHUPEOF

sed -i "s#__CATCHUP_MAX_AGE_DAYS__#${CATCHUP_MAX_AGE_DAYS}#g" /usr/local/sbin/reset-aluno-catchup.sh

chmod 700 /usr/local/sbin/reset-aluno-catchup.sh


# =====================================================================
# 20) SYSTEMD SERVICE + TIMER
# =====================================================================

echo "==> Criando serviços e timers systemd..."

cat > /etc/systemd/system/reset-aluno.service <<'SERVICEEOF'
[Unit]
Description=Reset do ambiente do aluno Fuctura (principal)
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reset-aluno.sh
SERVICEEOF

cat > /etc/systemd/system/reset-aluno-catchup.service <<'CATCHUPSERVICEEOF'
[Unit]
Description=Reset do ambiente do aluno Fuctura (recuperação)
After=postgresql.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reset-aluno-catchup.sh
CATCHUPSERVICEEOF

# Persistent=false nos dois: o reset só deve acontecer nesses horários
# fixos e previsíveis, nunca "assim que a máquina ligar" — que é
# justamente o comportamento perigoso que Persistent=true causaria
# (reset disparando no meio do uso do perfil principal).
cat > /etc/systemd/system/reset-aluno.timer <<'TIMEREOF'
[Unit]
Description=Reset semanal do ambiente Fuctura (principal)

[Timer]
OnCalendar=__RESET_SCHEDULE_PRIMARY__
Persistent=false
Unit=reset-aluno.service

[Install]
WantedBy=timers.target
TIMEREOF

cat > /etc/systemd/system/reset-aluno-catchup.timer <<'CATCHUPTIMEREOF'
[Unit]
Description=Reset semanal do ambiente Fuctura (recuperação, se o principal não rodou)

[Timer]
OnCalendar=__RESET_SCHEDULE_CATCHUP__
Persistent=false
Unit=reset-aluno-catchup.service

[Install]
WantedBy=timers.target
CATCHUPTIMEREOF

sed -i "s#__RESET_SCHEDULE_PRIMARY__#${RESET_SCHEDULE_PRIMARY}#g" /etc/systemd/system/reset-aluno.timer
sed -i "s#__RESET_SCHEDULE_CATCHUP__#${RESET_SCHEDULE_CATCHUP}#g" /etc/systemd/system/reset-aluno-catchup.timer

systemctl daemon-reload
systemctl enable --now reset-aluno.timer
systemctl enable --now reset-aluno-catchup.timer


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
if python3 --version >/dev/null 2>&1; then
    echo "✓ $(python3 --version)"
else
    echo "✗ Python não está funcionando."
fi
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
    echo "✓ PostgreSQL responde (autenticação local do usuário Linux postgres)."
else
    echo "✗ PostgreSQL não respondeu (autenticação local)."
fi
# O teste acima só prova que o usuário Linux "postgres" consegue conectar
# via peer auth — não que a senha configurada funciona por TCP, que é
# exatamente o caminho que o DBeaver (e qualquer cliente externo) usa.
if PGPASSWORD="$PG_PASSWORD" psql -h localhost -p "$PG_PORT" -U "$PG_USER" \
    -d "$PG_DEFAULT_DATABASE" -c "SELECT 1;" >/dev/null 2>&1; then
    PG_TCP_LOGIN_OK=true
    echo "✓ Login TCP com usuário/senha '${PG_USER}' confirmado (mesmo caminho do DBeaver)."
else
    PG_TCP_LOGIN_OK=false
    echo "✗ Login TCP com usuário/senha '${PG_USER}' falhou — a conexão do DBeaver não vai funcionar."
fi
echo

echo "[DBEAVER]"
if command -v dbeaver >/dev/null 2>&1; then
    echo "✓ DBeaver instalado."
else
    echo "✗ DBeaver não foi encontrado."
fi
if [[ "$DBEAVER_CONNECTION_OK" == true ]]; then
    echo "✓ Conexão PostgreSQL pré-configurada confirmada."
else
    echo "✗ Conexão do DBeaver não confirmada — revisar manualmente."
fi
echo

echo "[VS CODE]"
if command -v code >/dev/null 2>&1; then
    # Como root, o VS Code se recusa a iniciar (aviso de "superusuário")
    # e não imprime a versão — por isso checamos como o próprio aluno,
    # igual já fazemos com as extensões.
    echo "✓ $(sudo -u "$REAL_USER" env HOME="$REAL_HOME" code --version 2>/dev/null | head -n1)"
else
    echo "✗ VS Code não foi encontrado."
fi
echo

echo "[EXTENSÕES DO VS CODE]"
for ext in "${EXTENSIONS[@]}"; do
    if sudo -u "$REAL_USER" env HOME="$REAL_HOME" code --list-extensions 2>/dev/null | grep -Fxqi "$ext"; then
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
    echo "✓ Timer principal habilitado."
else
    echo "✗ Timer principal não está habilitado."
fi
if systemctl is-enabled --quiet reset-aluno-catchup.timer; then
    echo "✓ Timer de recuperação habilitado."
else
    echo "✗ Timer de recuperação não está habilitado."
fi
NEXT_RESET="$(systemctl show reset-aluno.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
if [[ -n "$NEXT_RESET" ]]; then
    echo "Próximo reset principal: $NEXT_RESET"
fi
NEXT_CATCHUP="$(systemctl show reset-aluno-catchup.timer -p NextElapseUSecRealtime --value 2>/dev/null || true)"
if [[ -n "$NEXT_CATCHUP" ]]; then
    echo "Próxima janela de recuperação: $NEXT_CATCHUP"
fi
echo

HAS_WARNINGS=false
(( ${#FAILED_EXTENSIONS[@]} > 0 )) && HAS_WARNINGS=true
[[ "$DBEAVER_CONNECTION_OK" == false ]] && HAS_WARNINGS=true
[[ "$PG_TCP_LOGIN_OK" == false ]] && HAS_WARNINGS=true
[[ "$OS_UNTESTED" == true ]] && HAS_WARNINGS=true

echo "=================================================================="
if [[ "$HAS_WARNINGS" == true ]]; then
    echo "           AMBIENTE FUCTURA PREPARADO COM AVISOS"
else
    echo "                 AMBIENTE FUCTURA PREPARADO"
fi
echo "=================================================================="
echo
echo "Usuário de aula : $REAL_USER"
echo "Sistema         : $PRETTY_NAME"
echo
echo "Reset principal : $RESET_SCHEDULE_PRIMARY"
echo "Recuperação     : $RESET_SCHEDULE_CATCHUP (só age se o principal não rodou)"
echo "Log completo    : $INSTALL_LOG"
echo
if (( ${#FAILED_EXTENSIONS[@]} > 0 )); then
    echo "AVISO: revise as extensões que falharam antes de liberar a máquina:"
    echo "       ${FAILED_EXTENSIONS[*]}"
    echo
fi
if [[ "$DBEAVER_CONNECTION_OK" == false ]]; then
    echo "AVISO: a conexão do DBeaver não foi confirmada — revisar manualmente."
    echo
fi
if [[ "$PG_TCP_LOGIN_OK" == false ]]; then
    echo "AVISO: login TCP do PostgreSQL falhou — o DBeaver não vai conseguir"
    echo "       conectar com as credenciais pré-configuradas. Revisar pg_hba.conf"
    echo "       e a senha do usuário ${PG_USER}."
    echo
fi
if [[ "$OS_UNTESTED" == true ]]; then
    echo "AVISO: esta versão do sistema (${PRETTY_NAME}) ainda não foi testada"
    echo "       com este script — revise o diagnóstico acima com atenção extra"
    echo "       antes de liberar a máquina."
    echo
fi
echo "Reprovisionar esta máquina no futuro: sudo ./setup-fuctura-labs.sh --force"
echo "=================================================================="
