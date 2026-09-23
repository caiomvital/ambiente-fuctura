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
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        --tailscale-key=*)
            TAILSCALE_AUTH_KEY="${arg#--tailscale-key=}"
            ;;
        *)
            echo "Argumento desconhecido: $arg"
            echo "Uso: sudo ./setup-fuctura-labs.sh [--force] --tailscale-key=SUA_CHAVE"
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

# Tailscale é OPCIONAL por enquanto (temporariamente desativado como
# obrigatório enquanto investigamos problema em algumas máquinas). Se a
# chave não for passada, o script simplesmente pula essa etapa mais
# abaixo e segue com o resto da instalação normalmente.


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


# ---------------------------------------------------------------------
# TAILSCALE (opcional — só roda se a chave for passada)
#
# Feito cedo de propósito: se a auth key estiver errada/expirada, é
# melhor descobrir agora do que depois de 10 minutos instalando
# JDK/Node/VS Code/DBeaver. O instalador oficial já detecta a distro
# sozinho (Ubuntu/Mint, qualquer versão), sem precisar da lógica de
# codename que usamos pro Adoptium/PGDG.
#
# --ssh habilita o Tailscale SSH: acesso remoto via `tailscale ssh
# usuario@maquina` usando a identidade da tailnet, sem precisar
# gerenciar chave SSH separada em cada máquina.
# ---------------------------------------------------------------------

if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
    echo "==> Instalando Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    echo "==> Conectando à tailnet..."
    if ! tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh; then
        echo "ERRO: falha ao conectar ao Tailscale — confira se a auth key é"
        echo "      válida e não expirou (chaves reutilizáveis expiram por"
        echo "      padrão em 90 dias, salvo se você desabilitou isso ao criá-la)."
        exit 1
    fi

    echo "✓ Tailscale conectado: $(tailscale ip -4 2>/dev/null || echo '(IP ainda não atribuído)')"
else
    echo "==> Nenhuma chave do Tailscale informada — pulando essa etapa por enquanto."
fi


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
       