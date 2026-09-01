# ambiente-fuctura

Script de provisionamento para padronizar as máquinas Linux da Fuctura
(Java 26 + Spring Boot + Angular + Python/Django), incluindo VS Code
com as extensões necessárias e reset semanal do perfil Aluno.

## Instalação

Em cada máquina, cole o comando abaixo no terminal (baixa, dá permissão
de execução e já roda com `sudo`, pedindo a senha do perfil Fuctura):

```bash
curl -fsSL https://raw.githubusercontent.com/caiomvital/ambiente-fuctura/main/setup-fuctura-labs.sh -o setup-fuctura-labs.sh && \
chmod +x setup-fuctura-labs.sh && \
sudo ./setup-fuctura-labs.sh
```

## O que o script instala

- **Java**: JDK 26 (Eclipse Temurin), Maven
- **Web**: Node.js 24 LTS + Angular CLI
- **Banco**: PostgreSQL
- **Python**: Python 3 + Django
- **Editor**: VS Code, com Extension Pack for Java, Spring Boot Extension
  Pack, Angular Language Service, Python, cliente PostgreSQL e Code
  Runner (já configurado pra rodar Java sem compilar antes e Python3,
  com execução no terminal para aceitar input do teclado)

## Reset semanal

Configura um timer do systemd que, toda semana, reseta o perfil `aluno`
(a partir do `/etc/skel`, então ele já volta com as extensões do VS Code
prontas) e apaga os bancos criados no PostgreSQL — sem afetar nada que
o script instalou no sistema.
