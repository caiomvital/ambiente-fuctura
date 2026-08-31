#!/usr/bin/env bash
#
# setup-fuctura-labs.sh
# Padroniza o ambiente de desenvolvimento nas máquinas da Fuctura.
#
# Cobre:
#   - Java  : JDK 26 (Eclipse Temurin) para os 4 módulos de Java
#             (Do Zero ao POO, JDBC/Hibernate+PostgreSQL, Spring Boot, Angular no backend)
#   - Node  : Node.js 24 LTS + Angular CLI (módulo 4 de Java)
#   - DB    : PostgreSQL (módulo 2 de Java: Hibernate)
#   - Build : Maven (módulo 3 de Java: Spring Boot)
#   - Python: Python 3 + Django (módulos 1 e 2 de Python)
#   - Editor: VS Code + extensões necessárias para todos os módulos acima
#
# Testado como equivalente ao "avançar, avançar, concluir": rode com sudo
# e ele faz tudo sem perguntar nada.
#
# PREMISSA: Ubuntu/Debian (apt). Se alguma máquina for Fedora/Arch, me avise
# que adapto os comandos (dnf/pacman) — a lista de pacotes é a mesma.
#
# Uso:
#   chmod +x setup-fuctura-labs.sh
#   sudo ./setup-fuctura-labs.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Rode como root/sudo: sudo ./setup-fuctura-labs.sh"
  exit 1
fi

# IMPORTANTE: nas máquinas da Fuctura, quem roda este script com sudo é o
# perfil "Fuctura" (admin) — mas quem usa o VS Code é o perfil "Aluno".
# Por isso as extensões/settings vão explicitamente pro perfil aluno, e
# NÃO para quem chamou o sudo (senão instalaria tudo no perfil errado).
REAL_USER="aluno"
if ! id "$REAL_USER" &>/dev/null; then
  echo "ERRO: usuário '$REAL_USER' não existe nesta máquina. Crie o perfil Aluno antes de rodar o script, ou ajuste a variável REAL_USER."
  exit 1
fi
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "==> Atualizando o sistema"
apt-get update -y
apt-get upgrade -y

echo "==> Instalando utilitários básicos"
apt-get install -y wget curl gpg apt-transport-https ca-certificates git software-properties-common

# -----------------------------------------------------------------------
# 1) JAVA 26 (Eclipse Temurin) — repositório oficial da Adoptium
# -----------------------------------------------------------------------
echo "==> Instalando JDK 26 (Eclipse Temurin)"
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/trusted.gpg.d/adoptium.gpg
echo "deb https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print $2}' /etc/os-release) main" \
  > /etc/apt/sources.list.d/adoptium.list
apt-get update -y
apt-get install -y temurin-26-jdk

# Garante que o java/javac padrão da máquina seja o 26 (caso haja outra versão)
JAVA26_BIN=$(ls -d /usr/lib/jvm/temurin-26-jdk-* 2>/dev/null | head -n1)
if [[ -n "$JAVA26_BIN" ]]; then
  update-alternatives --set java "$JAVA26_BIN/bin/java" || true
  update-alternatives --set javac "$JAVA26_BIN/bin/javac" || true
  echo "export JAVA_HOME=$JAVA26_BIN" > /etc/profile.d/java_home.sh
fi

# -----------------------------------------------------------------------
# 2) MAVEN — build do módulo Spring Boot
# -----------------------------------------------------------------------
echo "==> Instalando Maven"
apt-get install -y maven

# -----------------------------------------------------------------------
# 3) POSTGRESQL — módulo JDBC/Hibernate
# -----------------------------------------------------------------------
echo "==> Instalando PostgreSQL"
apt-get install -y postgresql postgresql-contrib
systemctl enable --now postgresql

# -----------------------------------------------------------------------
# 4) NODE.JS 24 LTS + ANGULAR CLI — módulo Angular
# -----------------------------------------------------------------------
echo "==> Instalando Node.js 24 LTS"
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt-get install -y nodejs

echo "==> Instalando Angular CLI globalmente"
npm install -g @angular/cli

# -----------------------------------------------------------------------
# 5) PYTHON + DJANGO — módulos Python
# -----------------------------------------------------------------------
echo "==> Instalando Python 3, pip, venv e Django"
apt-get install -y python3 python3-pip python3-venv python3-django

# -----------------------------------------------------------------------
# 6) VS CODE — repositório oficial da Microsoft
# -----------------------------------------------------------------------
echo "==> Instalando VS Code"
wget -qO- https://packages.microsoft.com/keys.microsoft.asc | gpg --dearmor > /tmp/packages.microsoft.gpg
install -D -o root -g root -m 644 /tmp/packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
  > /etc/apt/sources.list.d/vscode.list
rm -f /tmp/packages.microsoft.gpg
apt-get update -y
apt-get install -y code

# -----------------------------------------------------------------------
# 7) EXTENSÕES DO VS CODE — precisam rodar como o usuário real, não root
# -----------------------------------------------------------------------
echo "==> Instalando extensões do VS Code para o usuário $REAL_USER"
EXTENSIONS=(
  vscjava.vscode-java-pack        # Java completo: Language Support, Debugger, Test Runner, Maven, Project Manager
  vmware.vscode-boot-dev-pack     # Spring Boot: dashboard, initializr, properties, tools
  Angular.ng-template              # Angular Language Service
  ms-python.python                 # Python (traz o Pylance junto)
  ms-ossdata.vscode-pgsql          # Cliente PostgreSQL integrado
  formulahendry.code-runner        # Botão "play" para rodar Java/Python direto no editor
)

for ext in "${EXTENSIONS[@]}"; do
  sudo -u "$REAL_USER" code --install-extension "$ext" --force || true
done

# -----------------------------------------------------------------------
# 8) CODE RUNNER — executorMap para Java (source-launcher, sem compilar
#    antes) e Python3, + execução no terminal (senão IO.readln()/input()
#    travam, porque o painel de Output padrão do Code Runner não aceita
#    digitação).
# -----------------------------------------------------------------------
echo "==> Configurando o Code Runner (Java + Python)"
SETTINGS_DIR="$REAL_HOME/.config/Code/User"
mkdir -p "$SETTINGS_DIR"
chown "$REAL_USER":"$REAL_USER" "$SETTINGS_DIR" 2>/dev/null || true

sudo -u "$REAL_USER" env HOME="$REAL_HOME" python3 - "$SETTINGS_DIR/settings.json" <<'PYEOF'
import json, sys, os

path = sys.argv[1]
if os.path.exists(path):
    with open(path, "r") as f:
        try:
            settings = json.load(f)
        except json.JSONDecodeError:
            settings = {}
else:
    settings = {}

settings.setdefault("code-runner.executorMap", {})
# "java $fileName" usa o source-launcher do JDK: roda o .java direto,
# sem precisar compilar antes. Funciona tanto com "public class X"
# quanto com void main() sem classe (unnamed class).
settings["code-runner.executorMap"]["java"] = "cd $dir && java $fileName"
settings["code-runner.executorMap"]["python"] = "python3 -u $fileName"

settings["code-runner.runInTerminal"] = True
settings["code-runner.saveFileBeforeRun"] = True
settings["code-runner.clearPreviousOutput"] = True

with open(path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
PYEOF

# Copia extensões + settings do Code Runner para /etc/skel, assim contas
# NOVAS que forem criadas na máquina já nascem com tudo pronto (útil se a
# Fuctura usa um usuário genérico por aluno/turma).
if [[ -d "$REAL_HOME/.vscode/extensions" ]]; then
  mkdir -p /etc/skel/.vscode
  cp -r "$REAL_HOME/.vscode/extensions" /etc/skel/.vscode/ || true
fi
if [[ -f "$SETTINGS_DIR/settings.json" ]]; then
  mkdir -p /etc/skel/.config/Code/User
  cp "$SETTINGS_DIR/settings.json" /etc/skel/.config/Code/User/settings.json || true
fi

# -----------------------------------------------------------------------
# 9) RESET SEMANAL DO PERFIL ALUNO + BANCOS DO POSTGRESQL
#    Apaga /home/aluno e recria a partir do /etc/skel (que já tem as
#    extensões e o settings.json do VS Code configurados acima), e também
#    apaga os bancos que os alunos criaram no PostgreSQL durante a semana.
#    Não toca em nada instalado pelas seções anteriores — JDK, Maven, o
#    SERVIDOR do PostgreSQL, Node e o próprio binário do VS Code vivem em
#    /usr, /opt e /etc, fora de /home, então continuam intactos.
# -----------------------------------------------------------------------
echo "==> Configurando reset semanal do perfil Aluno + bancos do PostgreSQL"

cat > /usr/local/sbin/reset-aluno.sh <<'RESETEOF'
#!/usr/bin/env bash
set -euo pipefail

USER_TO_RESET="aluno"
USER_PASS="aluno"
HOME_DIR="/home/$USER_TO_RESET"
LOG="/var/log/reset-aluno.log"

# Bancos que NUNCA são apagados. Se algum curso precisar manter um banco
# fixo entre semanas, adicione o nome dele aqui.
PROTECTED_DBS=("postgres" "template0" "template1")
# Senha previsível do usuário postgres depois do reset, pra bater com o
# que é ensinado em aula. Troque aqui se usarem outra.
PG_SUPERUSER_PASSWORD="postgres"

echo "$(date '+%F %T') - iniciando reset do perfil $USER_TO_RESET" >> "$LOG"

# Encerra qualquer sessão ativa do aluno antes de mexer no home dele
loginctl terminate-user "$USER_TO_RESET" 2>/dev/null || true
pkill -KILL -u "$USER_TO_RESET" 2>/dev/null || true
sleep 2

# Apaga e recria o home a partir do /etc/skel
rm -rf "${HOME_DIR:?}"
mkdir -p "$HOME_DIR"
cp -a /etc/skel/. "$HOME_DIR/"
chown -R "$USER_TO_RESET:$USER_TO_RESET" "$HOME_DIR"
chmod 750 "$HOME_DIR"

# Garante que a senha continua sendo "aluno", caso tenham trocado
echo "$USER_TO_RESET:$USER_PASS" | chpasswd

echo "$(date '+%F %T') - reset do perfil concluído" >> "$LOG"

# ---- Reset dos bancos do PostgreSQL ----
echo "$(date '+%F %T') - iniciando reset do PostgreSQL" >> "$LOG"

DBS=$(sudo -u postgres psql -tAc "SELECT datname FROM pg_database WHERE datistemplate = false;")
for db in $DBS; do
  protected=false
  for p in "${PROTECTED_DBS[@]}"; do
    [[ "$db" == "$p" ]] && protected=true
  done
  if [[ "$protected" == false ]]; then
    echo "$(date '+%F %T') - apagando banco: $db" >> "$LOG"
    sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db';" >/dev/null 2>&1 || true
    sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$db\";" >> "$LOG" 2>&1
  fi
done

# Garante que a senha do usuário postgres continua previsível pros alunos
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '$PG_SUPERUSER_PASSWORD';" >> "$LOG" 2>&1

echo "$(date '+%F %T') - reset do PostgreSQL concluído" >> "$LOG"
RESETEOF
chmod 700 /usr/local/sbin/reset-aluno.sh

cat > /etc/systemd/system/reset-aluno.service <<'SERVICEEOF'
[Unit]
Description=Reseta o perfil do usuário aluno

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/reset-aluno.sh
SERVICEEOF

# Por padrão roda domingo às 23:30 (fora do horário de aula). Ajuste o
# OnCalendar se quiser outro dia/horário.
cat > /etc/systemd/system/reset-aluno.timer <<'TIMEREOF'
[Unit]
Description=Roda o reset do perfil aluno toda semana

[Timer]
OnCalendar=Sun *-*-* 23:30:00
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable --now reset-aluno.timer

echo ""
echo "=================================================================="
echo "Instalação concluída."
echo "Java :  $(java --version | head -n1)"
echo "Maven:  $(mvn --version | head -n1)"
echo "Node :  $(node --version)"
echo "ng   :  $(ng version --version 2>/dev/null || echo 'ok - use ng version dentro de um projeto')"
echo "Python: $(python3 --version)"
echo "Psql :  $(psql --version)"
echo "Code :  $(code --version | head -n1)"
echo "Reset semanal do Aluno: $(systemctl is-enabled reset-aluno.timer) - próxima execução: $(systemctl show reset-aluno.timer -p NextElapseUSecRealtime --value)"
echo "=================================================================="
