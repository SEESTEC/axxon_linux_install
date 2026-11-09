# Axxon One — Instalador Linux

Instalador do **Axxon One VMS** (Server ou Client) para **Ubuntu 24.04 LTS ou superior**, com retomada automática em caso de falha.

Desenvolvido por SEESTEC — Engenharia e Tecnologia.

## Requisitos

- Ubuntu **24.04 LTS ou superior** (outras distros/versões são recusadas)
- Acesso de administrador (`sudo`)
- Internet com acesso a `download.axxonsoft.com` (HTTPS)
- 5 GB livres em disco
- Server: `systemd` ativo (no WSL, `[boot] systemd=true` em `/etc/wsl.conf`)

## Uso

```bash
wget https://raw.githubusercontent.com/SEESTEC/axxon_linux_install/main/install.sh
sudo bash install.sh
```

Um menu pergunta se você quer instalar o **Server** ou o **Client**. Também dá para escolher pela linha de comando:

```bash
sudo bash install.sh --server              # Axxon One Server (pacote axxon-one)
sudo bash install.sh --client              # Axxon One Client (pacote axxon-one-client)
sudo bash install.sh --server -y           # sem perguntas, valores padrão do debconf
sudo bash install.sh --server --domain MEU_DOMINIO
sudo bash install.sh --client --version 3.1.0.8   # versão específica
sudo bash install.sh --client --language en       # idioma do Client
sudo bash install.sh --reset               # descarta o checkpoint e refaz tudo
sudo bash install.sh --remove              # remove Axxon One, repositório e checkpoint
```

## Versão instalada

Server e Client usam o mesmo `axxon-one-core` com versão exata, então os dois ficam sempre na mesma versão:

- **Já existe Axxon One na máquina** (ex.: Server instalado e agora o Client): o instalador usa a versão já instalada. O Server não é atualizado sem você pedir.
- **Máquina sem Axxon One**: usa a versão mais recente do repositório.
- **`--version VER`**: usa essa versão. Se ela for diferente da instalada, o instalador pede confirmação e atualiza Server e Client juntos.

Antes de baixar qualquer coisa, a instalação é simulada. Se algum pacote `axxon-*` já instalado fosse removido ou mudasse para outra versão, o instalador cancela.

## Idioma do Client

Na primeira execução, cada usuário do Client grava um idioma a partir do locale do sistema. No WSL o locale padrão é `C.UTF-8`: o Client grava `CultureName="C"`, que o mono não reconhece, e depois **não consegue conectar ao Server** (`NullReferenceException` ao criar o canal gRPC).

O instalador evita isso:

- Com o locale do sistema em `C`/`POSIX`, define `pt-BR` como idioma padrão do Client (`UI_FIRST_START_DEFAULT_LOCALE` em `/etc/AxxonSoft/axxon-one-client.conf`, pelo debconf do pacote). Em outros locales mantém `[OS Language]`.
- `--language CULTURA` escolhe outro idioma (`en`, `es`, `pt-PT`...).
- Perfis de usuário que já gravaram `C`/`POSIX` (`~/.local/share/AxxonSoft/AxxonOne/user.config`) são corrigidos, com backup. O Client desse usuário precisa estar fechado.

No modo interativo, o próprio pacote Axxon pergunta domínio, portas e logs. O domínio pode ficar em branco e ser definido no Client na primeira conexão.

## Etapas

| # | Etapa | O que faz |
|---|-------|-----------|
| 1 | Limpeza | remove entradas antigas do repositório Axxon e a chave do `apt-key` (com backup em `/var/lib/axxon-install/backup`) |
| 2 | Reparo | `dpkg --configure -a` e `apt --fix-broken install` (instalações interrompidas) |
| 3 | Dependências | `ca-certificates`, `wget`, `gnupg` |
| 4 | Chave GPG | baixa e valida a chave em `/etc/apt/keyrings/axxonsoft.gpg` |
| 5 | Repositório | grava `/etc/apt/sources.list.d/axxonsoft.list` e `/etc/apt/preferences.d/axxonsoft` |
| 6 | apt update | atualiza a lista de pacotes e confirma que o pacote está disponível |
| 7 | Versão | escolhe a versão, monta a lista `pacote=versão`, fixa o mono exigido pelo Client em `/etc/apt/preferences.d/axxonsoft-mono` e simula a instalação |
| 8 | Download | baixa todos os `.deb` antes de instalar |
| 9 | Instalação | `apt-get install` da lista com versões exatas |
| 10 | Idioma do Client | idioma padrão válido e correção de perfis com cultura `C` (só se o Client estiver instalado) |
| 11 | Serviço (Server) | habilita e aguarda o `axxon-one.service` ficar ativo |

## Retomada

O progresso fica em `/var/lib/axxon-install/state`. Se a instalação parar no meio (queda de internet, falta de energia, Ctrl+C), execute o script de novo: ele mostra o progresso e retoma da etapa que falhou. Antes de pular uma etapa já concluída, o script confere se o resultado dela continua válido. Os pacotes já baixados (inclusive downloads parciais) ficam no cache do apt e são reaproveitados.

O log completo fica em `/var/log/axxon-install.log`.

## Repositório Axxon no Ubuntu 24.04

O instalador usa o repositório da [documentação oficial](https://docs.axxonsoft.com/confluence/spaces/one1en/pages/226953742/Installing+from+repository), com estes ajustes para o Ubuntu 24.04:

- **Chave em keyring dedicado** (`signed-by`): o `apt-key` da documentação está obsoleto.
- **`buster backports/main`**: fornece a `libicu63`, exigida pelo `axxon-one-core` (não existe no Ubuntu 24.04), e o mono 6.12, exigido pelo Client 3.2+.
- **`stretch backports/mono-6_4`**: fornece o mono 6.4, versão exata exigida pelo Client 3.1. O Ubuntu 24.04 traz o 6.8.
- **Prioridades do apt**: os pacotes Debian do repositório Axxon têm prioridade baixa (100), para nunca substituírem pacotes do Ubuntu. Só os pacotes `axxon-*` têm preferência. O mono exato que a versão do Client exige é lido das dependências do pacote e fixado em `/etc/apt/preferences.d/axxonsoft-mono`.

## Solução de problemas

| Sintoma | Solução |
|---------|---------|
| "Sistema operacional incompatível" | Use Ubuntu 24.04 LTS ou superior |
| "Outra execução do instalador já está em andamento" | Aguarde a outra execução terminar |
| "não está disponível no repositório" | A versão instalada saiu do repositório: atualize tudo com `--version` (veja as versões listadas) |
| Client não conecta ("Connection failed", `Culture name C is not supported` no log) | `sudo bash install.sh --client` com o Client fechado; no Client use o endereço `127.0.0.1` ou o nome do servidor, sem a porta 8000 (que é a do Web Client) |
| Falha na etapa de download/apt update | Verifique internet/proxy/DNS e execute de novo |
| Serviço não sobe | `sudo journalctl -u axxon-one -n 100` |
| Reconfigurar o Server | `sudo dpkg-reconfigure axxon-one` |
| Idioma/logs do Client | `sudo dpkg-reconfigure axxon-one-client` |

## Licença

[MIT](LICENSE)
