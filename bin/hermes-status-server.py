#!/usr/bin/env python3
"""
Hermes status HTTP server for HF Space.
FastAPI + uvicorn — robust port binding, auto-handles signals.

Endpoints:
  GET /         → JSON status (ledger size, episodes, daemons, disk)
  GET /health   → simple {"ok": true}
  GET /logs     → tail of recent boot/cron logs (debug)
"""
from __future__ import annotations

import os
import sqlite3
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import asyncio
from typing import Any

from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

app = FastAPI(title="hermes", docs_url=None, redoc_url=None)

HOME = Path(os.environ.get("HOME", "/home/hermes"))
LEDGER = HOME / ".surrogate/state/scrape-ledger.db"
EPISODES = HOME / ".surrogate/state/surrogate-memory/episodes.jsonl"
LOG_DIR = HOME / ".surrogate/logs"


def _ledger_count() -> int:
    try:
        with sqlite3.connect(str(LEDGER), timeout=2) as c:
            return c.execute("SELECT COUNT(*) FROM scraped").fetchone()[0]
    except Exception:
        return 0


def _episodes_count() -> int:
    try:
        if EPISODES.exists():
            return sum(1 for _ in EPISODES.open())
    except Exception:
        pass
    return 0


def _daemons() -> int:
    try:
        out = subprocess.run(
            ["pgrep", "-fc", "discord-bot|surrogate-dev|scrape-loop|hermes-cron|ollama"],
            capture_output=True, text=True, timeout=2,
        )
        return int(out.stdout.strip() or 0)
    except Exception:
        return 0


@app.get("/")
def root() -> JSONResponse:
    return JSONResponse({
        "service": "hermes",
        "model": "axentx/surrogate-1",
        "status": "ok",
        "ts": datetime.now(timezone.utc).isoformat(),
        "ledger_repos": _ledger_count(),
        "episodes": _episodes_count(),
        "daemons_running": _daemons(),
    })


@app.get("/health")
def health() -> dict:
    return {"ok": True}


class ChatRequest(BaseModel):
    prompt: str
    cwd: str | None = None
    max_steps: int = 12
    timeout_sec: int = 180


@app.post("/chat")
async def chat(req: ChatRequest) -> JSONResponse:
    """Run a prompt through the surrogate CLI inside the container, return result.
    Used by remote Surrogate CLI clients (Mac/laptop) to delegate to Hermes brain on HF.
    """
    if not req.prompt.strip():
        raise HTTPException(status_code=400, detail="prompt is empty")

    surrogate_bin = HOME / ".surrogate/bin/surrogate"
    if not surrogate_bin.exists():
        raise HTTPException(status_code=503, detail="surrogate CLI not installed in container")

    proc = await asyncio.create_subprocess_exec(
        str(surrogate_bin), "-p", req.prompt, "--max-steps", str(req.max_steps),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=req.cwd or str(HOME),
        env={**os.environ, "TERM": "dumb"},
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=req.timeout_sec)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        raise HTTPException(status_code=504, detail=f"timeout after {req.timeout_sec}s")

    out = stdout.decode("utf-8", errors="replace")
    err = stderr.decode("utf-8", errors="replace")

    # Strip ANSI for clean JSON output
    import re as _re
    out = _re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", out)
    out = _re.sub(r"\x1b\[\?[0-9]+[hl]", "", out)
    out = "\n".join(l for l in out.splitlines() if not l.strip().startswith(("⏺", "●"))).strip()

    return JSONResponse({
        "ok": proc.returncode == 0,
        "rc": proc.returncode or 0,
        "response": out or "(empty)",
        "stderr_tail": err[-1000:] if err else "",
    })


@app.get("/logs")
def logs() -> PlainTextResponse:
    out_lines: list[str] = []
    for log_name in ("boot.log", "cron.log", "discord-bot.log", "ollama.log"):
        f = LOG_DIR / log_name
        if not f.exists():
            continue
        try:
            tail = f.read_text(errors="replace").splitlines()[-10:]
            out_lines.append(f"━━━ {log_name} ━━━")
            out_lines.extend(tail)
            out_lines.append("")
        except Exception:
            pass
    return PlainTextResponse("\n".join(out_lines) or "(no logs)")


if __name__ == "__main__":
    import os, sys, uvicorn
    port = int(os.environ.get("PORT", "7860"))
    print(f"[hermes] starting uvicorn on 0.0.0.0:{port}", flush=True)
    print(f"[hermes] python={sys.version.split()[0]} home={HOME}", flush=True)
    uvicorn.run(app, host="0.0.0.0", port=port, log_level="info", access_log=True)
