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
- [Solução de problemas](#solução-de-problemas)
- [Licença](#licença)

---

## Pré-requisitos

| Requisito                    | Versão mínima                                          |
|------------------------------|--------------------------------------------------------|
| Sistema operacional          | Ubuntu **24.04 LTS**                                   |
| Usuário com permissão `sudo` | —                                                      |
| Sessão gráfica               | **X11 (Xorg)** — Wayland não é suportado para gravação |
| Conexão com a internet       | —                                                      |

> **Wayland vs X11:** Ubuntu 24.04 usa Wayland por padrão. Para a gravação de tela funcionar, faça login selecionando **"Ubuntu on Xorg"** na engrenagem de opções da tela de login.

---

## Estrutura do projeto

```
axxon_linux_install/
├── install.sh              # Instalador interativo do Axxon One
└── screenREC/
    ├── screenREC.sh        # Daemon de gravação de tela (inicia com o Axxon)
    └── zip_daily.sh        # Cron job — arquiva gravações do dia anterior às 06h
```

---

## Download rápido

Clone o repositório ou baixe os arquivos individualmente com `wget`.

### Opção 1 — Clone completo

```bash
git clone https://github.com/raphaelseestec/axxon_linux_install.git
cd axxon_linux_install
```

### Opção 2 — Download individual com wget

```bash
# Criar estrutura de diretórios
mkdir -p axxon_linux_install/screenREC
cd axxon_linux_install

# Instalador principal
wget -O install.sh \
  https://raw.githubusercontent.com/raphaelseestec/axxon_linux_install/main/install.sh

# Gravação de tela
wget -O screenREC/screenREC.sh \
  https://raw.githubusercontent.com/raphaelseestec/axxon_linux_install/main/screenREC/screenREC.sh

# Arquivamento diário
wget -O screenREC/zip_daily.sh \
  https://raw.githubusercontent.com/raphaelseestec/axxon_linux_install/main/screenREC/zip_daily.sh
```

### Permissionar todos os scripts de uma vez

```bash
chmod +x install.sh screenREC/screenREC.sh screenREC/zip_daily.sh
```

---

## 1. Instalação do Axxon One

### O que o script faz

1. Verifica se o SO é Ubuntu 24.04 LTS — encerra se não for
2. Menu interativo para escolher o **tipo** (Server ou Client)
3. Menu interativo para escolher a **versão** (2.0 ou 3.0)
4. Atualiza o sistema (`apt update && apt upgrade`)
5. Instala dependências: `curl`, `unzip`, `wget`
6. Adiciona aliases e banner informativo ao `~/.bashrc`
7. Faz o download do pacote correto direto do CDN da Axxon
8. Extrai e instala os pacotes `.deb` na ordem correta

### Versões disponíveis

| Tipo | Versão | Build | Tamanho |
|---|---|---|---|
| Server | 2.0 | 2.0.14.79 | ~1,0 GB |
| Client | 2.0 | 2.0.14.79 | ~1,1 GB |
| Server | 3.0 | 3.0.0.46 | ~1,5 GB |
| Client | 3.0 | 3.0.0.46 | ~1,6 GB |

### Como executar

```bash
# Dar permissão de execução (se ainda não tiver)
chmod +x install.sh

# Executar
sudo bash install.sh
```

> O script requer `sudo` para instalar pacotes e configurar repositórios.

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

```bash
axxon-start    # sudo systemctl start axxon-one
axxon-stop     # sudo systemctl stop axxon-one
axxon-restart  # sudo systemctl restart axxon-one
axxon-status   # sudo systemctl status axxon-one
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

- Aguarda o processo `AxxonSoft` iniciar
- Detecta automaticamente todos os monitores conectados via `xrandr`
- Detecta automaticamente as fontes de áudio via `pactl` (PipeWire/PulseAudio)
- Inicia uma gravação por monitor, **todas com áudio** (microfone + saída de som mesclados)
- Ao detectar que o Axxon foi fechado, finaliza todas as gravações graciosamente
- Renomeia cada arquivo com `hora_início-hora_fim`
- Registra o cron de arquivamento diário automaticamente na primeira execução

### Pré-requisito: sessão X11

A gravação usa `x11grab` (ffmpeg). Verifique sua sessão atual:

```bash
echo $XDG_SESSION_TYPE
# Deve retornar: x11
```

Se retornar `wayland`, faça logout e, na tela de login, clique na **engrenagem** no canto inferior direito e selecione **"Ubuntu on Xorg"**.

### Dependências instaladas automaticamente

O script verifica e instala o que estiver faltando:

| Pacote | Função |
|---|---|
| `ffmpeg` | Captura e codificação de vídeo/áudio |
| `x11-xserver-utils` | Detecção de monitores (`xrandr`) |
| `pipewire-pulse` | Captura de áudio PipeWire/PulseAudio (`pactl`) |
| `zip` | Compactação das gravações pelo cron diário |

### Como executar

```bash
chmod +x screenREC/screenREC.sh

# Executar em foreground (Ctrl+C para parar manualmente)
bash screenREC/screenREC.sh

# Executar em background (recomendado para uso contínuo)
nohup bash screenREC/screenREC.sh > /tmp/screenrec.log 2>&1 &
echo "PID: $!"
```

Para acompanhar o log em tempo real:

```bash
tail -f /tmp/screenrec.log
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
- `REC_SHARE` será configurada como pasta Samba (compartilhamento de rede) em etapa futura

#### Exemplo real

```
/home/operador/REC_SHARE/
└── SN1234ABC_2026-05-07_08-30-00/
    ├── monitor1_08-30-01-12-45-30.mp4   # tela principal, ~4h de gravação
    └── monitor2_08-30-01-12-45-30.mp4   # segunda tela, mesmo período
```

### Configurações de vídeo

| Parâmetro | Valor |
|---|---|
| Codec de vídeo | `libx264 -preset ultrafast` |
| Codec de áudio | `aac` |
| Frame rate | 30 fps |
| Canais de áudio | 2 (stereo — microfone + saída mesclados) |
| Container | MP4 |

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

O download pode ter sido interrompido. Delete o diretório temporário e execute o script novamente. O script usa `mktemp -d` e limpa automaticamente com `trap`.

---

### Gravação de tela

**"Sessão Wayland detectada"**
```bash
# Verificar sessão atual
echo $XDG_SESSION_TYPE

# Forçar X11 no próximo login (GNOME)
echo "WaylandEnable=false" | sudo tee -a /etc/gdm3/custom.conf
# Depois faça logout e login novamente
```

**"Nenhum monitor detectado via xrandr"**
```bash
# Verificar se xrandr está funcionando
xrandr --listmonitors

# Se retornar erro, certifique-se de estar em sessão X11
echo $DISPLAY   # deve retornar algo como ":0"
```

**Sem áudio na gravação**
```bash
# Verificar se PipeWire/PulseAudio está ativo
pactl info

# Listar fontes de áudio disponíveis
pactl list short sources

# Testar captura de áudio manualmente (5 segundos)
ffmpeg -f pulse -i default -t 5 /tmp/teste_audio.mp3
```

**Arquivo de vídeo corrompido ou vazio após encerramento forçado**

O `screenREC.sh` envia `SIGINT` ao ffmpeg ao detectar o fechamento do Axxon, garantindo que o container MP4 seja fechado corretamente. Se o processo for `kill -9`'d (SIGKILL), o arquivo pode ficar incompleto. Para tentar recuperar:

```bash
ffmpeg -i arquivo_corrompido.mp4 -c copy arquivo_recuperado.mp4
```

---

### Cron e arquivamento

**Cron não executa**
```bash
# Verificar se o serviço está ativo
systemctl status cron

# Iniciar se necessário
sudo systemctl enable --now cron

# Testar execução manual
bash screenREC/zip_daily.sh
cat /tmp/screenrec_zip.log
```

**"Nenhuma pasta encontrada"**
```bash
# Verificar o serial number usado pelo script
cat /sys/class/dmi/id/product_serial
head -c 12 /etc/machine-id   # fallback

# Listar pastas existentes no REC_SHARE
ls -la ~/REC_SHARE/
```

**Sem espaço em disco**
```bash
# Verificar espaço
df -h ~/REC_SHARE

# As gravações em MP4 (ultrafast) consomem aproximadamente:
# Monitor 1080p @ 30fps → ~1,5 GB/hora por monitor
```

---

## Licença

MIT License — Copyright (c) 2026 [raphaelseestec](https://github.com/raphaelseestec)

Consulte o arquivo [LICENSE](./LICENSE) para os termos completos.
