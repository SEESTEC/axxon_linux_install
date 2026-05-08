#!/usr/bin/env python3
"""
ask_tag.py  —  Define a tag de identificação da sessão de gravação Axxon One.
Salva TAG=<valor> em ~/screenREC/.env (preserva as outras variáveis do arquivo).
Interface: zenity (GNOME) com fallback automático para tkinter.
"""

import os
import subprocess
import shutil
import sys

SCREENREC_DIR = os.path.expanduser("~/screenREC")
ENV_FILE      = os.path.join(SCREENREC_DIR, ".env")
TITLE         = "Axxon One — Identificação de Gravação"
LABEL         = "Tag para esta sessão de gravação:\n(usada como prefixo da pasta em ~/REC_SHARE)"


# ── helpers ───────────────────────────────────────────────────────────────────

def _sudo_pass() -> str:
    if not os.path.exists(ENV_FILE):
        return ""
    with open(ENV_FILE) as f:
        for line in f:
            if line.startswith("SUDO_PASS="):
                return line.strip().split("=", 1)[1]
    return ""


def _apt_install(pkg: str) -> bool:
    pw = _sudo_pass()
    try:
        if pw:
            r = subprocess.run(
                ["sudo", "-S", "apt-get", "install", "-y", pkg],
                input=pw + "\n", text=True, capture_output=True,
            )
        else:
            r = subprocess.run(
                ["sudo", "apt-get", "install", "-y", pkg],
                capture_output=True,
            )
        return r.returncode == 0
    except Exception:
        return False


def _ensure(binary: str, pkg: str) -> bool:
    if shutil.which(binary):
        return True
    print(f"Instalando dependência: {pkg}...", flush=True)
    return _apt_install(pkg) and shutil.which(binary) is not None


# ── leitura / escrita do .env ─────────────────────────────────────────────────

def read_tag() -> str:
    if not os.path.exists(ENV_FILE):
        return ""
    with open(ENV_FILE) as f:
        for line in f:
            if line.startswith("TAG="):
                return line.strip().split("=", 1)[1].strip("\"'")
    return ""


def save_tag(tag: str) -> None:
    os.makedirs(SCREENREC_DIR, exist_ok=True)
    lines: list[str] = []
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            lines = [ln for ln in f if not ln.startswith("TAG=")]
    lines.append(f"TAG={tag}\n")
    with open(ENV_FILE, "w") as f:
        f.writelines(lines)
    os.chmod(ENV_FILE, 0o600)


# ── backends de dialog ────────────────────────────────────────────────────────

def ask_zenity(current: str) -> str | None:
    if not _ensure("zenity", "zenity"):
        return None
    try:
        r = subprocess.run(
            [
                "zenity", "--entry",
                f"--title={TITLE}",
                f"--text={LABEL}",
                f"--entry-text={current}",
                "--width=480",
            ],
            capture_output=True, text=True,
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception:
        return None


def ask_tkinter(current: str) -> str | None:
    if not _ensure("python3", "python3-tk"):
        return None
    try:
        import tkinter as tk
        from tkinter import simpledialog

        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        tag = simpledialog.askstring(TITLE, LABEL, initialvalue=current, parent=root)
        root.destroy()
        return tag.strip() if tag else None
    except Exception:
        return None


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    # Sem display → sem dialog; mantém tag existente silenciosamente
    if not os.environ.get("DISPLAY"):
        sys.exit(0)

    current = read_tag()
    tag = ask_zenity(current) or ask_tkinter(current)

    if not tag:
        sys.exit(0)

    save_tag(tag)
    # Imprime para o shell pai capturar se necessário
    print(f"TAG={tag}", flush=True)


if __name__ == "__main__":
    main()
