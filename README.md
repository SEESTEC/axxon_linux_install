# Axxon One — Instalador Linux

Instalador do **Axxon One VMS** (Server ou Client) para **Ubuntu 24.04 LTS ou superior**, com retomada automática em caso de falha, painel web opcional (uma página exibida como câmera) e o comando `axxon`, que lista todos os comandos de terminal.

| Arquivo | Para quê |
|---------|----------|
| `install.sh` | instala o Server ou o Client (e, no Server, opcionalmente o painel web) |
| `webpanel.sh` | instala e gerencia o painel web à parte, num Server já instalado |
| `axxon.sh` | comando `axxon` (lista de comandos), instalado pelos dois scripts acima |

Desenvolvido por SEESTEC — Engenharia e Tecnologia.

## Requisitos

- Ubuntu **24.04 LTS ou superior** (outras distros/versões são recusadas)
- Acesso de administrador (`sudo`)
- Internet com acesso a `download.axxonsoft.com` (HTTPS)
- 5 GB livres em disco
- Server: `systemd` ativo (no WSL, `[boot] systemd=true` em `/etc/wsl.conf`)
- Painel web: Server instalado na mesma máquina, arquitetura **amd64** (Google Chrome) e acesso HTTPS a `dl.google.com` e `github.com`

## Uso

```bash
wget https://raw.githubusercontent.com/SEESTEC/axxon_linux_install/main/install.sh
sudo bash install.sh
```

Um menu pergunta se você quer instalar o **Server** ou o **Client**. No Server, o instalador também pergunta se você quer um painel web e, nesse caso, pede e testa a URL logo no início. No modo interativo, o próprio pacote Axxon pergunta domínio, portas e logs; o domínio pode ficar em branco e ser definido no Client na primeira conexão.

Também dá para escolher pela linha de comando:

```bash
sudo bash install.sh --server              # Axxon One Server (pacote axxon-one)
sudo bash install.sh --client              # Axxon One Client (pacote axxon-one-client)
sudo bash install.sh --server -y           # sem perguntas, valores padrão do debconf
sudo bash install.sh --server --domain MEU_DOMINIO
sudo bash install.sh --client --version 3.1.0.8   # versão específica
sudo bash install.sh --client --language en       # idioma do Client
sudo bash install.sh --server --webpanel              # Server + painel web (pergunta a URL)
sudo bash install.sh --server --webpanel-url https://painel.local   # Server + painel web, URL já informada
sudo bash install.sh --server --no-webpanel        # não pergunta pelo painel web
sudo bash install.sh --reset               # descarta o checkpoint e refaz tudo
sudo bash install.sh --remove              # remove Axxon One, painel web, comando axxon, repositório e checkpoint
sudo bash install.sh --help                # todas as opções
```

Depois de instalar, `axxon --help` lista todos os comandos de terminal da máquina.

## Comando `axxon`

Os dois instaladores (`install.sh` e `webpanel.sh`) instalam o comando **`axxon`** (`/usr/local/bin/axxon`, a partir do `axxon.sh` deste repositório). Ele lista todos os comandos de terminal do Axxon One da máquina, com a versão e o estado de cada parte (Server, Client, painel web e instalador), e os nomes dos seus aliases `axxon*` do `~/.bashrc`. As definições dos aliases não aparecem, porque podem conter senhas.

```bash
axxon            # ou axxon --help
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
| 12 | Painel web (Server, opcional) | executa o `webpanel.sh` (veja abaixo) |

Ao final, o instalador instala (ou atualiza) o comando `axxon`. Uma falha nessa parte só gera um aviso.

## Painel web (página exibida como câmera)

O Client Linux do Axxon One **não tem o Web Board** ([limitação documentada pela AxxonSoft](https://docs.axxonsoft.com/confluence/spaces/ONE2025/pages/314539502/Features+and+potential+problems+with+Linux+OS)). O `webpanel.sh` contorna isso: um Google Chrome sem tela (Xvfb) abre a página, o ffmpeg transforma a tela em vídeo H.264 e o MediaMTX publica em RTSP **só em localhost**. A página é cadastrada no Axxon One Server como uma câmera (driver `FFMPEG / 1 channel device`, sem gravação) e vai para o layout como qualquer câmera.

É só visualização: não dá para clicar nem rolar a página. Ela conta como um canal na licença do Axxon One.

**Pelo instalador (Server):** no modo interativo ele pergunta se você quer o painel e pede a URL logo no início, testando a página antes de seguir (URL inválida é recusada e perguntada de novo). Com `-y`, use `--webpanel-url URL`. Se o painel já estiver instalado, o instalador mantém a página atual (mesmo que tenha sido trocada com `axxon-web`); só `--webpanel-url` a substitui.

**Sozinho** (Server já instalado):

```bash
wget https://raw.githubusercontent.com/SEESTEC/axxon_linux_install/main/webpanel.sh
sudo bash webpanel.sh                       # pergunta a URL e testa
sudo bash webpanel.sh install --url URL -y  # sem perguntas
sudo bash webpanel.sh --help                # opções (--name, --rtsp-port, --allow-user...)
```

O script:

1. confere o Ubuntu (24.04+, amd64), o Axxon One Server instalado e ativo, e **detecta a versão**;
2. confere o **driver pack**: o pacote `axxon-drivers-pack`, o driver FFMPEG e o modelo usado, e avisa se houver versão mais nova;
3. pede e **testa a URL** (http/https: a página precisa responder; 401/403/404 pedem confirmação; `file://`: o arquivo precisa existir e ser legível);
4. autentica na API do Axxon One (tenta `root`/`root`; se não funcionar, pergunta usuário e senha, sem gravá-los; para automação: `AXXON_USER`/`AXXON_PASSWORD`);
5. instala Xvfb, ffmpeg, fontes, Google Chrome (pacote oficial) e MediaMTX (versão fixa, **SHA-256 conferido**);
6. cria o usuário de serviço `axxon_web`, os serviços `axxon-webpanel` e `axxon-webpanel-rtsp` (reinício automático, recarga da página a cada 6 h) e uma política do Chrome que desliga o tradutor e outros avisos;
7. verifica o vídeo, cadastra a câmera (sem duplicar, se já existir) e confirma que o Axxon recebe a imagem;
8. instala o comando `axxon-webpanel`, os aliases **`axxon-web`** e **`axxon-dashboard`** para todos os usuários (`/etc/bash.bashrc`) e o comando `axxon`;
9. libera a troca de página **sem senha** para o grupo `axxonweb` (`/etc/sudoers.d/axxon-webpanel`, validado com `visudo`, só `url`, `status` e `restart`). Entra no grupo quem rodou o `sudo`; outros usuários: `--allow-user USUARIO` ou `sudo usermod -aG axxonweb USUARIO`. Vale a partir de um terminal novo. O `remove` continua exigindo senha.

O painel roda como o usuário de sistema `axxon_web` (sem login, sem senha e sem shell): o navegador não roda como root e o painel funciona sem ninguém logado. Nenhum outro usuário é criado.

**Trocar a página** (testa a nova URL antes de aplicar):

```bash
axxon-web                    # ou axxon-dashboard — pergunta a nova URL (Enter mantém, q cancela)
axxon-webpanel url URL       # direto
axxon-webpanel status        # serviços, stream e câmera
axxon-webpanel restart       # recarrega a página
axxon-webpanel logs
sudo axxon-webpanel remove   # remove o painel (e, se confirmado, a câmera; --keep-camera mantém)
```

Resolução, fps, taxa de bits e intervalo de recarga ficam em `/etc/axxon-webpanel/webpanel.conf` (depois: `axxon-webpanel restart`). Log: `/var/log/axxon-webpanel.log`. Portas: RTSP `127.0.0.1:8654` (a `8554` é do próprio Axxon).

Se a página exige login, o painel mostra a tela de login: prefira uma URL com token ou um usuário só de visualização.

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
| Painel web sem imagem | `axxon-webpanel status` (serviços e stream) e `axxon-webpanel logs`; `axxon-webpanel restart` recarrega a página |
| `axxon-web` pede senha | Abra um terminal novo; se continuar, o usuário não está no grupo: `sudo usermod -aG axxonweb USUARIO` (ou `webpanel.sh install --allow-user USUARIO`) |
| "localhost" na URL do painel não abre | No WSL, `localhost` é o Linux, não o Windows: use o IP do Windows ou da máquina |
| Falha na etapa de download/apt update | Verifique internet/proxy/DNS e execute de novo |
| Serviço não sobe | `sudo journalctl -u axxon-one -n 100` |
| Reconfigurar o Server | `sudo dpkg-reconfigure axxon-one` |
| Idioma do Client | `sudo bash install.sh --client --language CULTURA` (com o Client fechado) |
| Logs do Client | `sudo dpkg-reconfigure axxon-one-client` |
| Não lembro um comando | `axxon --help` |

## Licença

[MIT](LICENSE)
