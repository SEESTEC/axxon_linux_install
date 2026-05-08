# Axxon One — Instalador Linux

Instalador interativo do **Axxon One VMS** (Server e Client) para **Ubuntu 24.04 LTS**, com gravação automática de telas enquanto o client estiver aberto e arquivamento diário das gravações.

Desenvolvido por [SEESTEC — Engenharia e Tecnologia](https://github.com/raphaelseestec).

---

## Índice

- [Pré-requisitos](#pré-requisitos)
- [Estrutura do projeto](#estrutura-do-projeto)
- [Download rápido](#download-rápido)
- [1. Instalação do Axxon One](#1-instalação-do-axxon-one)
- [2. Gravação de telas (screenREC)](#2-gravação-de-telas-screensrec)
- [3. Arquivamento diário (zip\_daily)](#3-arquivamento-diário-zip_daily)
- [4. Servidor Samba (setup\_samba)](#4-servidor-samba-setup_samba)
- [Solução de problemas](#solução-de-problemas)
- [Licença](#licença)

---

## Pré-requisitos

| Requisito                    | Versão mínima                                          |
|------------------------------|--------------------------------------------------------|
| Sistema operacional          | Ubuntu **24.04 LTS**                                   |
| Usuário com permissão `sudo` | —                                                      |
| Sessão gráfica               | **X11 (Xorg)** — Wayland não é suportado para gravação |
| Conexão com a internet       | Necessário conexão estável com permissão do firewall   |

> **Wayland vs X11:** O instalador desabilita o Wayland por 6 métodos independentes e o `screenREC.sh` verifica a sessão automaticamente a cada inicialização. Se Wayland for detectado, a correção é aplicada sem intervenção do usuário e um alerta é exibido na tela pedindo apenas um logout/login.

---

## Estrutura do projeto

```
axxon_linux_install/
├── install.sh              # Instalador interativo do Axxon One
└── screenREC/
    ├── screenREC.sh        # Daemon de gravação de tela (inicia com o Axxon)
    ├── zip_daily.sh        # Cron job — arquiva gravações do dia anterior às 06h
    ├── setup_samba.sh      # Instalador e configurador do servidor Samba
    ├── ask_tag.py          # Dialog de tag — abre ao detectar o Axxon iniciando
    └── find_rec.py         # Busca de gravações por data e hora
```

---

## Download rápido

```bash
wget -v -O ~/axxon_linux_install.sh https://bit.ly/axxon_linux_install && sudo bash ~/axxon_linux_install.sh
```

---

## 1. Instalação do Axxon One

### O que o script faz

**Comum (Server e Client):**

1. Verifica conexão com a internet — aguarda ou encerra
2. Verifica se o SO é Ubuntu 24.04 LTS — encerra se não for
3. Menu interativo para escolher o **tipo** (Server ou Client)
4. Menu interativo para escolher a **versão** (2.0 ou 3.0)
5. Atualiza o sistema (`apt update && apt upgrade`)
6. Instala dependências: `curl`, `unzip`, `wget`
7. Adiciona aliases e banner informativo ao `~/.bashrc`
8. Faz o download do pacote correto direto do CDN da Axxon
9. Extrai e instala os pacotes `.deb` na ordem correta
10. Desabilita a interface de rede externa (DHCP) — mantém a rede local privada

**Exclusivo Client:**

11. Baixa `screenREC.sh`, `zip_daily.sh` e `setup_samba.sh` para `~/screenREC/`
12. Cria entrada de autostart GNOME para `screenREC` (`~/.config/autostart/screenREC.desktop`)
13. Instala e configura o servidor Samba (`REC_SHARE`)
14. Salva a senha sudo em `~/screenREC/.env` para uso pelos scripts automatizados
15. Desabilita Wayland e força Xorg por 6 métodos independentes
16. Reinicia o sistema automaticamente

### Versões disponíveis

| Tipo   | Versão | Build     | Tamanho |
|--------|--------|-----------|---------|
| Server | 2.0    | 2.0.14.79 | ~1,0 GB |
| Client | 2.0    | 2.0.14.79 | ~1,1 GB |
| Server | 3.0    | 3.0.0.46  | ~1,5 GB |
| Client | 3.0    | 3.0.0.46  | ~1,6 GB |

### Como executar

```bash
# Dar permissão de execução (se ainda não tiver)
chmod +x install.sh

# Executar
sudo bash install.sh
```

> O script requer `sudo` para instalar pacotes e configurar repositórios.

### Retomada automática de instalação

O instalador mantém um **checkpoint** em `/var/tmp/axxon_install.checkpoint` e armazena o pacote baixado em `/var/tmp/axxon_install/`. Se a instalação for interrompida (queda de internet, falha de energia, erro de rede), basta garantir uma conexão estável e executar o script novamente:

```bash
sudo bash install.sh   # retoma do ponto de interrupção
```

Ao ser reiniciado, o script exibe o progresso anterior e pergunta se deseja retomar ou iniciar do zero:

```
╔══════════════════════════════════════════════════════╗
║      AXXON ONE — Instalação Anterior Detectada       ║
╠══════════════════════════════════════════════════════╣
║  Tipo    : client                                    ║
║  Versão  : 2.0                                       ║
║                                                      ║
║  Progresso dos passos:                               ║
║  ✓  Atualização do sistema                           ║
║  ✓  Aliases no .bashrc                               ║
║  ✓  Download do pacote Axxon                         ║
║  ○  Extração do pacote                               ║
║  ○  Repositório e chave GPG                          ║
║  ○  Instalação dos pacotes .deb                      ║
║  ○  Scripts screenREC                                ║
║  ○  Autostart screenREC                              ║
║  ○  Servidor Samba                                   ║
║  ○  Credencial sudo                                  ║
║  ○  Desabilitar Wayland                              ║
║  ○  Desabilitar rede externa                         ║
╚══════════════════════════════════════════════════════╝

Retomar instalação? [S/N ou qualquer outra tecla para sair]:
```

**Comportamento por passo:**

| Passo | Comportamento ao retomar |
|---|---|
| Download do pacote     | `wget -c` retoma o arquivo parcial — não baixa novamente |
| Extração               | Reexecuta se o diretório não existir |
| Instalação `.deb`      | Pula se já marcado como concluído |
| Scripts screenREC      | `wget -c` em cada arquivo — seguro repetir |
| Samba, Autostart, etc. | Pula se já marcados como concluídos |

O checkpoint é **removido automaticamente** ao final de uma instalação bem-sucedida.

### Fluxo interativo

```
╔════════════════════════════════════════╗
║     AXXON ONE — Instalador Linux       ║
╠════════════════════════════════════════╣
║  1) Server                             ║
║  2) Client                             ║
║  3) Sair                               ║
╚════════════════════════════════════════╝
Escolha o tipo de instalação [1-3]: _
```

Em cada etapa de confirmação:
- **S** → confirma e avança
- **N** → volta ao menu anterior
- **Qualquer outra tecla** → encerra a instalação

### Aliases instalados no `~/.bashrc`

Após a instalação, os seguintes comandos ficam disponíveis (reinicie o terminal):

**Axxon One — serviço**
```bash
axxon-start      # inicia o serviço Axxon One
axxon-stop       # para o serviço Axxon One
axxon-restart    # reinicia o serviço Axxon One
axxon-status     # exibe o status do serviço
```

**Identificação e busca**
```bash
ask-tag          # abre o dialog de tag de identificação manualmente
find-rec         # busca gravações por data e hora
```

**screenREC — controle**
```bash
screenREC-start  # inicia o screenREC em background (nohup)
screenREC-stop   # envia sinal de encerramento (finaliza gravações corretamente)
screenREC-status # verifica se há gravações ativas (ffmpeg)
screenREC-live   # acompanha o log do screenREC em tempo real
```

**screenREC — log de arquivamento**
```bash
screenREC-log    # histórico completo do log de arquivamento (zip_daily)
screenREC-show   # acompanha o log de arquivamento em tempo real
screenREC-ok     # filtra apenas arquivamentos concluídos com sucesso
screenREC-error  # filtra apenas erros no log de arquivamento
```

**screenREC — diagnóstico**
```bash
screenREC-session     # tipo de sessão gráfica e valor de $DISPLAY
screenREC-monitors    # lista monitores detectados via xrandr
screenREC-audio       # informações do servidor PipeWire/PulseAudio
screenREC-audio-list  # lista fontes de áudio disponíveis
screenREC-audio-test  # grava 5s de teste em /tmp/teste_audio.mp3
screenREC-serial      # exibe o serial DMI e machine-id do hardware
screenREC-folder      # lista pastas em ~/REC_SHARE/
screenREC-autostart   # exibe o conteúdo do desktop entry de autostart
screenREC-cron             # lista entradas cron registradas pelo screenREC
screenREC-disk             # uso de disco do REC_SHARE
screenREC-cleanup-log      # histórico completo do log de limpeza (cleanup_old)
screenREC-cleanup-show     # acompanha o log de limpeza em tempo real
```

**Samba — controle e diagnóstico**
```bash
samba-status   # status dos serviços smbd e nmbd
samba-restart  # reinicia smbd e nmbd
samba-users    # lista usuários com senha Samba cadastrada
samba-passwd   # redefine a senha Samba do usuário atual
samba-test     # testa conexão local ao compartilhamento REC_SHARE
```

### Repositório e chave GPG

O instalador configura automaticamente o repositório da Axxon e importa a chave GPG:

```
/etc/apt/sources.list.d/axxonsoft.list
/etc/apt/trusted.gpg.d/axxonsoft.gpg
```

Essas operações são **idempotentes** — não duplicam entradas se o script for executado mais de uma vez.

---

## 2. Gravação de telas (screenREC)

### O que o script faz

- **Verifica o tipo de sessão gráfica** — se Wayland for detectado, aplica a correção para X11 automaticamente e exibe um alerta; se X11, continua normalmente
- Aguarda o processo `AxxonSoft` iniciar
- Detecta automaticamente todos os monitores conectados via `xrandr`
- Detecta automaticamente as fontes de áudio via `pactl` (PipeWire/PulseAudio)
- Inicia uma gravação por monitor, **todas com áudio** (microfone + saída de som mesclados)
- Ao detectar que o Axxon foi fechado, finaliza todas as gravações graciosamente
- Renomeia cada arquivo com `hora_início-hora_fim`
- Registra o cron de arquivamento diário automaticamente na primeira execução

### Sessão gráfica

A gravação usa `x11grab` (ffmpeg), que requer uma sessão X11. O `screenREC.sh` verifica automaticamente o tipo de sessão ao iniciar:

- **X11 detectado** → gravação inicia normalmente, sem intervenção do usuário
- **Wayland detectado** → o script tenta aplicar a correção para X11 automaticamente (usando a senha sudo salva pelo instalador); em seguida exibe um alerta na área de trabalho e encerra

O usuário só precisa agir se receber o alerta — nesse caso, basta fazer **logout e login novamente** para que a sessão já inicie em X11.

### Dependências instaladas automaticamente

O script verifica e instala o que estiver faltando:

| Pacote              | Função                                         |
|---------------------|------------------------------------------------|
| `ffmpeg`            | Captura e codificação de vídeo/áudio           |
| `x11-xserver-utils` | Detecção de monitores (`xrandr`)               |
| `pipewire-pulse`    | Captura de áudio PipeWire/PulseAudio (`pactl`) |
| `zip`               | Compactação das gravações pelo cron diário     |

### Tag de identificação (ask\_tag.py)

A cada vez que o **Axxon One é detectado iniciando**, o `screenREC.sh` abre automaticamente uma janela de dialog pedindo a tag que será usada como prefixo da pasta de gravação em `~/REC_SHARE/`. A tag é salva em `~/screenREC/.env` e reutilizada como valor padrão na próxima sessão.

```
┌─────────────────────────────────────────────┐
│  Axxon One — Identificação de Gravação      │
│                                             │
│  Tag para esta sessão de gravação:          │
│  (usada como prefixo da pasta em REC_SHARE) │
│                                             │
│  [ TAG00_________________________ ]         │
│                                             │
│        [ Cancelar ]  [ OK ]                 │
└─────────────────────────────────────────────┘
```

**Resultado em `~/REC_SHARE/`:**

```
REC_SHARE/
└── TAG00_2026-05-08_08-30-00/
    ├── monitor1_08-30-01-12-45-30.mp4
    └── monitor2_08-30-01-12-45-30.mp4
```

**Alias para abrir o dialog manualmente** (disponível após reiniciar o terminal):

```bash
ask-tag
```

**Dependências verificadas/instaladas automaticamente** pelo script:

| Pacote       | Função                                             |
|--------------|----------------------------------------------------|
| `zenity`     | Dialog nativo GNOME (preferido)                    |
| `python3-tk` | Fallback tkinter caso zenity não esteja disponível |

### Busca de gravações (`find-rec`)

Permite localizar arquivos de gravação por data e hora com uma interface gráfica nativa.

**Alias** (disponível após reiniciar o terminal):

```bash
find-rec
```

**Fluxo de uso:**

1. Um calendário é aberto para selecionar a **data** da gravação
2. Uma caixa de texto pede o **horário** no formato `HH:MM` (ex: `09:30`)
3. O programa busca em `REC_SHARE` por arquivos cujo intervalo de gravação cobre o horário informado

**Critérios de busca:**

| Categoria             | Critério                                                                    |
|-----------------------|-----------------------------------------------------------------------------|
| **Resultado exato**   | Arquivos onde `início ≤ horário ≤ fim` da gravação                          |
| **Horários próximos** | Arquivos com início ou fim a no máximo **±30 minutos** do horário informado |

**Exemplo de resultado:**

```
GRAVAÇÃO ATIVA ÀS 09:30  (2026-05-08)
────────────────────────────────────────────────────────────────────────────
/home/operador/REC_SHARE/TAG00_2026-05-08_08-30-00/monitor1_08-30-01-12-45-30.mp4
/home/operador/REC_SHARE/TAG00_2026-05-08_08-30-00/monitor2_08-30-01-12-45-30.mp4

HORÁRIOS PRÓXIMOS  (±30 min de 09:30)  [2026-05-08]
────────────────────────────────────────────────────────────────────────────
[+15 min]  /home/operador/REC_SHARE/TAG00_2026-05-08_08-30-00/monitor1_09-45-00-10-30-00.mp4
```

O caminho completo de cada arquivo é exibido em fonte monoespaçada, facilitando a cópia para uso no explorador de arquivos ou acesso via Samba.

### Autostart no login

O `install.sh` cria `~/.config/autostart/screenREC.desktop` automaticamente durante a instalação. O `screenREC.sh` também verifica a entrada ao iniciar e a recria se estiver ausente — nenhuma ação manual é necessária.

```bash
screenREC-autostart   # exibe o conteúdo do desktop entry de autostart
screenREC-status      # verifica se o ffmpeg está gravando
screenREC-live        # acompanha o log do screenREC em tempo real
```

### Controle manual

```bash
screenREC-start   # inicia em background com nohup
screenREC-stop    # encerra as gravações corretamente (SIGTERM → ffmpeg fecha o MP4)
screenREC-status  # verifica se há gravações ativas
screenREC-live    # acompanha o log em tempo real
```

### Estrutura de pastas gerada

```
/home/$USER/REC_SHARE/
└── {SERIAL}_{YYYY-MM-DD_HH-MM-SS}/      ← criada no início do 1º dia de gravação
    ├── monitor1_{HH-MM-SS}-{HH-MM-SS}.mp4
    ├── monitor2_{HH-MM-SS}-{HH-MM-SS}.mp4
    └── monitorN_{HH-MM-SS}-{HH-MM-SS}.mp4
```

- **`SERIAL`** — serial number do hardware (`/sys/class/dmi/id/product_serial`) ou os primeiros 12 caracteres do `machine-id` como fallback
- Gravações do **mesmo dia** são salvas na **mesma pasta**
- Cada novo dia cria uma nova pasta com o timestamp do início da primeira gravação
- `REC_SHARE` é compartilhada via Samba na rede local (configurado pelo `setup_samba.sh`)

#### Exemplo real

```
/home/operador/REC_SHARE/
└── SN1234ABC_2026-05-07_08-30-00/
    ├── monitor1_08-30-01-12-45-30.mp4   # tela principal, ~4h de gravação
    └── monitor2_08-30-01-12-45-30.mp4   # segunda tela, mesmo período
```

### Configurações de vídeo

| Parâmetro       | Valor                                    |
|-----------------|------------------------------------------|
| Codec de vídeo  | `libx264 -preset ultrafast`              |
| Codec de áudio  | `aac`                                    |
| Frame rate      | 30 fps                                   |
| Canais de áudio | 2 (stereo — microfone + saída mesclados) |
| Container       | MP4                                      |

---

## 3. Arquivamento diário (zip\_daily)

### O que o script faz

Executado automaticamente pelo cron às **06:00** (horário local do host):

1. Identifica a(s) pasta(s) de gravação do **dia anterior**
2. Compacta cada pasta em um `.zip`
3. Remove a pasta original **somente** se o zip foi concluído com sucesso
4. Registra tudo em `/tmp/screenrec_zip.log`

### Instalação do cron (automática)

O `screenREC.sh` instala a entrada do cron automaticamente na primeira execução. Para verificar:

```bash
crontab -l | grep zip_daily
# Saída esperada:
# 0 6 * * * /caminho/para/screenREC/zip_daily.sh >> /tmp/screenrec_zip.log 2>&1
```

### Instalação manual do cron

Caso precise instalar manualmente:

```bash
# 1. Dar permissão de execução
chmod +x screenREC/zip_daily.sh

# 2. Obter o caminho absoluto do script
SCRIPT_PATH="$(realpath screenREC/zip_daily.sh)"

# 3. Registrar no cron
(crontab -l 2>/dev/null; echo "0 6 * * * $SCRIPT_PATH >> /tmp/screenrec_zip.log 2>&1") | crontab -

# 4. Verificar
crontab -l
```

### Resultado gerado pelo cron

```
/home/$USER/REC_SHARE/
├── SN1234ABC_2026-05-06_08-30-00.zip   ← pasta do dia anterior, compactada
└── SN1234ABC_2026-05-07_08-30-00/      ← pasta do dia atual, ainda em gravação
    ├── monitor1_08-30-01-...mp4
    └── monitor2_08-30-01-...mp4
```

### Monitorar o log do cron

Os aliases abaixo são instalados automaticamente pelo `install.sh` e ficam disponíveis após reiniciar o terminal:

```bash
screenREC-log    # Histórico completo do log de arquivamento
screenREC-show   # Acompanhar em tempo real (tail -f)
screenREC-ok     # Filtrar apenas arquivamentos concluídos com sucesso
screenREC-error  # Filtrar apenas erros
```

Equivalentes manuais (caso os aliases não estejam disponíveis):

```bash
# Histórico completo
cat /tmp/screenrec_zip.log

# Tempo real
tail -f /tmp/screenrec_zip.log

# Apenas sucessos
grep "Concluído" /tmp/screenrec_zip.log

# Apenas erros
grep "ERRO" /tmp/screenrec_zip.log
```

---

## 4. Servidor Samba (setup\_samba)

### O que o script faz

1. Instala `samba`, `samba-common-bin` e `zenity`
2. **Detecta os discos montados** na máquina e pergunta ao usuário onde armazenar as gravações:
   - **1 disco:** usa-o automaticamente, sem dialog
   - **Múltiplos discos:** abre radiolist zenity para o usuário escolher; fallback para menu numerado no terminal se não houver sessão gráfica
3. Cria `REC_SHARE/` no disco escolhido com permissões corretas
4. Faz backup de `/etc/samba/smb.conf` → `/etc/samba/smb.conf.bak`
5. Adiciona ou atualiza a seção `[REC_SHARE]` no `smb.conf` (idempotente — re-execuções apenas atualizam o `path`)
6. Define a senha Samba do usuário via `smbpasswd`
7. Libera a porta Samba no `ufw` (se ativo)
8. Habilita e inicia os serviços `smbd` e `nmbd`

### Seleção de disco

Quando mais de um disco real está montado, o script abre este dialog:

```
┌──────────────────────────────────────────────────────────────┐
│  Axxon One — Disco para REC_SHARE                            │
│                                                              │
│  Selecione o disco onde as gravações serão armazenadas:      │
│                                                              │
│  ( ) Ponto de montagem  Dispositivo   Tamanho  Disponível    │
│  (•) /                  /dev/sda1     500G     210G          │
│  ( ) /mnt/dados         /dev/sdb1     2,0T     1,8T          │
│  ( ) /media/backup      /dev/sdc1     4,0T     3,9T          │
│                                                              │
│                    [ Cancelar ]  [ OK ]                      │
└──────────────────────────────────────────────────────────────┘
```

O caminho criado segue a regra:

| Disco escolhido | Caminho de `REC_SHARE`          |
|-----------------|---------------------------------|
| `/` ou `/home`  | `~/REC_SHARE` (home do usuário) |
| `/mnt/dados`    | `/mnt/dados/REC_SHARE`          |
| `/media/backup` | `/media/backup/REC_SHARE`       |

### Instalação (automática via `install.sh`)

> **Instalação via `install.sh` Client:** o `setup_samba.sh` é executado automaticamente. Apenas responda as perguntas de senha durante o processo.

### Instalação manual

```bash
# Dar permissão de execução
chmod +x ~/screenREC/setup_samba.sh

# Executar com sudo
sudo bash ~/screenREC/setup_samba.sh
```

### Acessar o compartilhamento

| Sistema     | Caminho                           |
|-------------|-----------------------------------|
| Windows     | `\\HOSTNAME\REC_SHARE`            |
| Linux/macOS | `smb://HOSTNAME/REC_SHARE`        |
| Terminal    | `smbclient //HOSTNAME/REC_SHARE`  |

Substitua `HOSTNAME` pelo nome ou IP da máquina client na rede local.

### Verificar e gerenciar o serviço

```bash
# Status dos serviços
sudo systemctl status smbd nmbd

# Reiniciar após mudanças no smb.conf
sudo systemctl restart smbd nmbd

# Listar compartilhamentos ativos
smbclient -L localhost -U <usuario>

# Ver configuração atual do Samba
testparm
```

### Reconfigurar senha Samba

```bash
sudo smbpasswd <usuario>
```

### Reconfigurar disco / caminho do REC_SHARE

Basta reexecutar o script — ele detecta que `[REC_SHARE]` já existe e atualiza apenas o `path`:

```bash
sudo bash ~/screenREC/setup_samba.sh
```

### Estrutura do `smb.conf` adicionada

```ini
[REC_SHARE]
   comment = Gravações Axxon One — <usuario>
   path = /home/<usuario>/REC_SHARE
   browseable = yes
   read only = no
   guest ok = no
   valid users = <usuario>
   create mask = 0664
   directory mask = 0775
   force user = <usuario>
```

---

## Solução de problemas

### Instalação do Axxon

**"Sistema operacional incompatível"**
```bash
cat /etc/os-release | grep -E "^ID=|^VERSION_ID="
# Deve retornar: ID=ubuntu / VERSION_ID="24.04"
```

**`dpkg` trava ou pede configuração de domínio durante a instalação**

Isso é esperado. Durante a instalação do `axxon-one-core`, o sistema pode perguntar pelo nome de domínio do servidor. Pode deixar em branco — é configurável depois pelo client.

**"Pacotes .deb não encontrados"**

O download pode ter sido corrompido. Para forçar o re-download, remova o checkpoint e o pacote baixado e execute novamente:

```bash
sudo rm -f /var/tmp/axxon_install.checkpoint
sudo rm -rf /var/tmp/axxon_install
sudo bash ~/axxon_linux_install.sh
```

**Forçar instalação do zero (ignorar checkpoint)**

```bash
# Remove checkpoint e arquivos parciais
sudo rm -f /var/tmp/axxon_install.checkpoint
sudo rm -rf /var/tmp/axxon_install

# Execute normalmente — o instalador iniciará do início
sudo bash ~/axxon_linux_install.sh
```

**Verificar o estado atual do checkpoint**

```bash
cat /var/tmp/axxon_install.checkpoint
```

---

### Gravação de tela

**Alerta "Sessão gráfica incompatível" apareceu na tela**

O `screenREC.sh` detectou uma sessão Wayland e exibiu o alerta automaticamente. Se a mensagem diz **"configuração corrigida automaticamente"**, basta fazer logout e login novamente — na próxima sessão a gravação já iniciará normalmente.

Se a mensagem pede a troca manual, faça logout e, na tela de login, clique na **engrenagem** no canto inferior direito e selecione **"Ubuntu on Xorg"**.

**Verificar tipo de sessão e display (informativo)**
```bash
screenREC-session   # mostra XDG_SESSION_TYPE e $DISPLAY
```

**"Nenhum monitor detectado via xrandr"**

```bash
screenREC-session    # confirma tipo de sessão (xrandr requer X11)
screenREC-monitors   # lista monitores detectados via xrandr
```

**Sem áudio na gravação**

```bash
screenREC-audio        # informações do servidor PipeWire/PulseAudio
screenREC-audio-list   # lista todas as fontes de áudio disponíveis
screenREC-audio-test   # grava 5 segundos de teste em /tmp/teste_audio.mp3
```

**Arquivo de vídeo corrompido ou vazio após encerramento forçado**

O `screenREC.sh` envia `SIGINT` ao ffmpeg ao detectar o fechamento do Axxon, garantindo que o container MP4 seja fechado corretamente. Se o processo for `kill -9`'d (SIGKILL), o arquivo pode ficar incompleto. Para tentar recuperar:

```bash
ffmpeg -i arquivo_corrompido.mp4 -c copy arquivo_recuperado.mp4
```

---

### Cron e arquivamento

**Cron não executa**

O `screenREC.sh` verifica o serviço `cron` ao iniciar e o habilita automaticamente se estiver inativo — usando a senha sudo salva pelo instalador. Nenhuma ação manual é necessária.

```bash
screenREC-cron   # lista as entradas cron registradas pelo screenREC
screenREC-log    # verifica o log do último arquivamento
```

**"Nenhuma pasta encontrada"**

```bash
screenREC-serial   # exibe o serial DMI e machine-id usados como prefixo da pasta
screenREC-folder   # lista as pastas existentes em REC_SHARE
```

**Sem espaço em disco**

O script `cleanup_old.sh` gerencia o espaço em disco automaticamente — não é necessária nenhuma intervenção manual.

- Executa todos os dias às **05:00** via cron (registrado automaticamente pelo `screenREC.sh` na primeira execução)
- Remove todos os arquivos `.zip` com **mais de 45 dias** dentro de `REC_SHARE`
- Emite um **alerta no log** se o uso do disco permanecer acima de **85%** após a limpeza
- Se houver sessão gráfica ativa (`$DISPLAY`), exibe também uma notificação de área de trabalho via `notify-send`

```bash
screenREC-cleanup-log    # histórico completo do log de limpeza
screenREC-cleanup-show   # acompanha o log de limpeza em tempo real
screenREC-disk           # uso atual do disco REC_SHARE
```

> As gravações em MP4 (ultrafast) consomem aproximadamente **~1,5 GB/hora por monitor** (1080p @ 30 fps).

---

### Busca de gravações (`find-rec`)

**Nenhuma gravação encontrada para a data/hora informada**

- Confirme que o Axxon One estava em execução no horário buscado
- Confirme que o `screenREC.sh` estava ativo (`pgrep -a ffmpeg`)
- Verifique se a pasta existe: `ls ~/REC_SHARE/ | grep 2026-05-08` (substitua a data)
- O `find-rec` busca apenas arquivos `.mp4` dentro de `REC_SHARE` — arquivos já zipados (`.zip`) não aparecem nos resultados

**Horário de busca não coincide com nenhum arquivo**

O programa exibe automaticamente arquivos com horários próximos (±30 min). Se nenhum arquivo próximo aparecer, é provável que a gravação não estava ativa naquele período.

**`DISPLAY` não definido**

O `find-rec` verifica a sessão antes de abrir a interface. Use o alias de diagnóstico para confirmar:

```bash
screenREC-session   # mostra tipo de sessão e valor de $DISPLAY
```

---

### Samba

**Não consegue conectar ao compartilhamento**

```bash
samba-status   # verifica se smbd e nmbd estão ativos
samba-users    # lista usuários com senha Samba cadastrada
samba-test     # testa conexão local ao compartilhamento REC_SHARE
```

**"NT_STATUS_LOGON_FAILURE" ao conectar**

```bash
samba-passwd   # redefine a senha Samba do usuário atual
```

**Compartilhamento não aparece na rede**

O `setup_samba.sh` habilita os serviços e configura o firewall automaticamente. Se o compartilhamento desaparecer:

```bash
samba-restart   # reinicia smbd e nmbd
```

**screenREC não inicia automaticamente no login**

O `screenREC.sh` recria o desktop entry de autostart automaticamente ao ser executado. Para diagnóstico:

```bash
screenREC-autostart   # exibe o conteúdo do desktop entry
screenREC-status      # verifica se ffmpeg está rodando
screenREC-start       # inicia manualmente se necessário
```

---

## Licença

MIT License — Copyright (c) 2026 [raphaelseestec](https://github.com/raphaelseestec)

Consulte o arquivo [LICENSE](./LICENSE) para os termos completos.
