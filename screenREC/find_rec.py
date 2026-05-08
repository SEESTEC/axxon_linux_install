#!/usr/bin/env python3
"""find_rec.py — Busca arquivos de gravação por data e hora."""

import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path


# ── localização do REC_SHARE ──────────────────────────────────────────────────

def get_rec_base() -> Path:
    smb_conf = Path("/etc/samba/smb.conf")
    if smb_conf.exists():
        in_section = False
        for line in smb_conf.read_text(errors="replace").splitlines():
            s = line.strip()
            if s == "[REC_SHARE]":
                in_section = True
            elif s.startswith("[") and s != "[REC_SHARE]":
                in_section = False
            elif in_section and re.match(r"path\s*=", s):
                path = s.split("=", 1)[1].strip()
                if path:
                    return Path(path)
    return Path.home() / "REC_SHARE"


# ── zenity ────────────────────────────────────────────────────────────────────

def _zenity(*args: str, stdin_text: str | None = None) -> str | None:
    try:
        if stdin_text is not None:
            proc = subprocess.Popen(
                ["zenity", *args],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True,
            )
            stdout, _ = proc.communicate(input=stdin_text)
            return stdout.strip() if proc.returncode == 0 else None
        r = subprocess.run(
            ["zenity", *args],
            capture_output=True, text=True,
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except FileNotFoundError:
        return None


def _ensure_zenity() -> bool:
    if subprocess.run(["which", "zenity"], capture_output=True).returncode == 0:
        return True
    print("Instalando zenity...", flush=True)
    env_file = Path(__file__).parent / ".env"
    sudo_pass = ""
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("SUDO_PASS="):
                sudo_pass = line.split("=", 1)[1].strip().strip("\"'")
    if sudo_pass:
        cmd = f"echo {sudo_pass!r} | sudo -S apt-get install -y zenity"
    else:
        cmd = "sudo apt-get install -y zenity"
    return os.system(cmd) == 0


# ── diálogos de entrada ───────────────────────────────────────────────────────

def ask_date() -> str | None:
    now = datetime.now()
    return _zenity(
        "--calendar",
        "--title=Busca de Gravação — Axxon One",
        "--text=Selecione a <b>data</b> da gravação:",
        f"--year={now.year}",
        f"--month={now.month}",
        f"--day={now.day}",
        "--date-format=%Y-%m-%d",
    )


def ask_time() -> str | None:
    raw = _zenity(
        "--entry",
        "--title=Busca de Gravação — Axxon One",
        "--text=Digite o <b>horário</b> da gravação:\n<small>Formato: HH:MM (ex: 09:30)</small>",
        f"--entry-text={datetime.now().strftime('%H:%M')}",
    )
    if raw is None:
        return None
    raw = raw.strip()
    m = re.match(r"^(\d{1,2}):(\d{2})$", raw)
    if m:
        h, mi = int(m.group(1)), int(m.group(2))
        if 0 <= h <= 23 and 0 <= mi <= 59:
            return f"{h:02d}:{mi:02d}"
    _zenity(
        "--error",
        "--title=Busca de Gravação — Axxon One",
        "--text=Horário inválido. Use o formato HH:MM (ex: 09:30).",
        "--width=380",
    )
    return None


# ── parse do nome do arquivo ──────────────────────────────────────────────────
#
# Padrão: monitor{N}_{HH}-{MM}-{SS}-{HH}-{MM}-{SS}.mp4
#          monitor1_08-30-01-12-45-30.mp4
#
FILE_RE = re.compile(
    r"monitor(\d+)_(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})-(\d{2})\.mp4$"
)


def parse_times(name: str) -> tuple[int, int] | None:
    """Retorna (start_min, end_min) em minutos desde meia-noite, ou None."""
    m = FILE_RE.match(name)
    if not m:
        return None
    sh, sm, _ss, eh, em, _es = (int(x) for x in m.groups()[1:])
    return sh * 60 + sm, eh * 60 + em


# ── busca ─────────────────────────────────────────────────────────────────────

APPROX_WINDOW = 30   # minutos


def search(
    rec_base: Path, date_str: str, time_str: str
) -> tuple[list[str], list[tuple[int, str]]]:
    """
    Retorna:
      containing — arquivos cuja janela [start, end] cobre o horário pedido
      close      — (distância_min, caminho) de arquivos próximos (± APPROX_WINDOW min)
    """
    th, tm = map(int, time_str.split(":"))
    target = th * 60 + tm

    folders = sorted(rec_base.glob(f"*_{date_str}*"))

    containing: list[str] = []
    close: list[tuple[int, str]] = []

    for folder in folders:
        if not folder.is_dir():
            continue
        for mp4 in sorted(folder.glob("*.mp4")):
            times = parse_times(mp4.name)
            if times is None:
                continue
            start_m, end_m = times

            if start_m <= target <= end_m:
                containing.append(str(mp4))
            else:
                dist = min(abs(start_m - target), abs(end_m - target))
                if dist <= APPROX_WINDOW:
                    close.append((dist, str(mp4)))

    close.sort(key=lambda x: x[0])
    return containing, close


# ── exibição dos resultados ───────────────────────────────────────────────────

def show_results(
    date_str: str,
    time_str: str,
    containing: list[str],
    close: list[tuple[int, str]],
) -> None:
    if not containing and not close:
        _zenity(
            "--warning",
            "--title=Busca de Gravação — Axxon One",
            "--text="
            f"Nenhuma gravação encontrada para <b>{date_str}</b> às <b>{time_str}</b>.\n\n"
            "Verifique se:\n"
            "  • A data está correta\n"
            "  • O Axxon One estava em execução nesse horário\n"
            "  • O screenREC.sh estava ativo",
            "--width=480",
        )
        return

    lines: list[str] = []

    if containing:
        lines.append(f"GRAVAÇÃO ATIVA ÀS {time_str}  ({date_str})")
        lines.append("─" * 72)
        for p in containing:
            lines.append(p)

    if close:
        if lines:
            lines.append("")
        lines.append(
            f"HORÁRIOS PRÓXIMOS  (±{APPROX_WINDOW} min de {time_str})"
            f"  [{date_str}]"
        )
        lines.append("─" * 72)
        for dist, p in close:
            lines.append(f"[+{dist:02d} min]  {p}")

    text = "\n".join(lines)
    title = f"Gravação encontrada — {date_str} {time_str}"

    _zenity(
        "--text-info",
        f"--title={title}",
        "--width=960",
        "--height=480",
        "--font=monospace 10",
        stdin_text=text,
    )


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    if not os.environ.get("DISPLAY"):
        print("DISPLAY não definido. Execute em sessão X11.", file=sys.stderr)
        sys.exit(1)

    if not _ensure_zenity():
        print("Não foi possível instalar zenity.", file=sys.stderr)
        sys.exit(1)

    rec_base = get_rec_base()
    if not rec_base.exists():
        _zenity(
            "--error",
            "--title=Busca de Gravação — Axxon One",
            f"--text=Pasta REC_SHARE não encontrada:\n<tt>{rec_base}</tt>\n\n"
            "Execute o <tt>setup_samba.sh</tt> primeiro.",
            "--width=480",
        )
        sys.exit(1)

    date_str = ask_date()
    if date_str is None:
        sys.exit(0)

    time_str = ask_time()
    if time_str is None:
        sys.exit(0)

    containing, close = search(rec_base, date_str, time_str)
    show_results(date_str, time_str, containing, close)


if __name__ == "__main__":
    main()
