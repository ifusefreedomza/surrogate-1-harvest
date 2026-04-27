#!/usr/bin/env python3
"""
Hermes Discord Bot — bridges Discord ↔ surrogate CLI.

Triggers (responds when):
  1. DM (any message in private channel)
  2. Bot is @mentioned in a channel
  3. Message starts with prefix `!sg ` or `/sg`

Pipes user message → surrogate -p "..." → replies with output.

Token comes from $DISCORD_BOT_TOKEN (read from ~/.hermes/.env).
Logs to ~/.surrogate/logs/hermes-discord-bot.log.
"""
from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import subprocess
from pathlib import Path

import discord

# ── Config ───────────────────────────────────────────────────────────────────
HOME = Path.home()
LOG_PATH = HOME / ".surrogate/logs/hermes-discord-bot.log"
LOG_PATH.parent.mkdir(parents=True, exist_ok=True)

# surrogate CLI path: prefer ~/.local/bin (installed), fallback ~/.surrogate/bin
SURROGATE_BIN = next(
    p for p in [HOME / ".local/bin/surrogate", HOME / ".surrogate/bin/surrogate"] if p.exists()
)

PREFIX_RE = re.compile(r"^[!/]sg\b\s*", re.IGNORECASE)
TIMEOUT_SEC = 180  # 3-minute cap per request
DISCORD_MAX = 1900  # Discord per-message limit is 2000; reserve for code-fence + ellipsis
NOTIFY_DISCORD_LEVEL_TASK = "task"
HISTORY_TURNS = 6  # keep last 6 message pairs per channel for short-term context
HISTORY_TTL_SEC = 1800  # 30 min sliding window — drop convo if idle longer
HISTORY_DIR = HOME / ".surrogate/discord-history"
HISTORY_DIR.mkdir(parents=True, exist_ok=True)

# ── Logging ──────────────────────────────────────────────────────────────────
logging.basicConfig(
    filename=str(LOG_PATH),
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("hermes-bot")

TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
if not TOKEN:
    raise SystemExit("DISCORD_BOT_TOKEN not set — source ~/.hermes/.env first")

# ── Discord client ───────────────────────────────────────────────────────────
intents = discord.Intents.default()
intents.message_content = True  # privileged — must be enabled in dev portal
intents.dm_messages = True

client = discord.Client(intents=intents)


# ── Helpers ──────────────────────────────────────────────────────────────────
def chunk(text: str, n: int = DISCORD_MAX) -> list[str]:
    """Split text into <=n-char chunks at safe boundaries (newlines first)."""
    if len(text) <= n:
        return [text]
    chunks: list[str] = []
    while text:
        if len(text) <= n:
            chunks.append(text)
            break
        cut = text.rfind("\n", 0, n)
        if cut < n // 2:  # no decent newline → hard split
            cut = n
        chunks.append(text[:cut])
        text = text[cut:].lstrip("\n")
    return chunks


def _hist_path(channel_id: int) -> Path:
    return HISTORY_DIR / f"{channel_id}.json"


def load_history(channel_id: int) -> list[dict]:
    """Load recent conversation turns for this channel. Drops if expired."""
    import json, time
    p = _hist_path(channel_id)
    if not p.exists():
        return []
    try:
        data = json.loads(p.read_text())
        if time.time() - data.get("updated", 0) > HISTORY_TTL_SEC:
            return []  # stale — start fresh
        return data.get("turns", [])[-HISTORY_TURNS * 2:]
    except Exception:
        return []


def save_history(channel_id: int, turns: list[dict]) -> None:
    """Persist turns (trimmed) for this channel."""
    import json, time
    p = _hist_path(channel_id)
    try:
        p.write_text(json.dumps({
            "updated": time.time(),
            "turns": turns[-HISTORY_TURNS * 2:],
        }, ensure_ascii=False))
    except Exception as e:
        log.warning("save_history failed: %s", e)


def build_prompt_with_history(user_msg: str, history: list[dict]) -> str:
    """Embed prior turns as a [Context] block before the new user message."""
    if not history:
        return user_msg
    lines = ["[Conversation history — most recent first]"]
    for turn in reversed(history):
        role = turn.get("role", "user")
        text = turn.get("text", "").replace("\n", " ")[:400]
        lines.append(f"- {role}: {text}")
    lines.append("")
    lines.append(f"[Current message]\n{user_msg}")
    return "\n".join(lines)


async def call_surrogate(prompt: str, cwd: str | None = None) -> tuple[str, int]:
    """Invoke surrogate -p PROMPT; returns (output, returncode)."""
    proc = await asyncio.create_subprocess_exec(
        str(SURROGATE_BIN),
        "-p",
        prompt,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=cwd or str(HOME),
        env={**os.environ, "TERM": "dumb"},  # disable spinner / ANSI
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=TIMEOUT_SEC)
        rc = proc.returncode or 0
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return f"⏱️ Timed out after {TIMEOUT_SEC}s", 124

    out = stdout.decode("utf-8", errors="replace")
    err = stderr.decode("utf-8", errors="replace")

    # Strip ANSI escape sequences (just in case TERM=dumb didn't fully suppress)
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", out)
    out = re.sub(r"\x1b\[\?[0-9]+[hl]", "", out)
    # Drop spinner artifacts and "thinking..." line
    out = "\n".join(
        line for line in out.splitlines() if not line.strip().startswith(("⏺", "●"))
    ).strip()

    if not out and err:
        out = f"[stderr]\n{err[:1500]}"
    return out or "(empty response)", rc


# ── Event handlers ───────────────────────────────────────────────────────────
@client.event
async def on_ready() -> None:
    log.info("connected as %s (id=%s)", client.user, client.user.id if client.user else "?")
    print(f"✅ logged in as {client.user}")
    # Notify Discord channel via webhook that bot came online
    notify = HOME / ".surrogate/bin/notify-discord.sh"
    if notify.exists():
        subprocess.Popen(
            [str(notify), "success", "Discord bot online", f"Connected as {client.user}. DM or @mention to chat."],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


@client.event
async def on_message(msg: discord.Message) -> None:
    # Ignore self / other bots
    if msg.author.bot or (client.user and msg.author.id == client.user.id):
        return

    # Determine trigger
    is_dm = isinstance(msg.channel, (discord.DMChannel, discord.PartialMessageable))
    is_mention = client.user is not None and client.user in msg.mentions
    has_prefix = bool(PREFIX_RE.match(msg.content))

    if not (is_dm or is_mention or has_prefix):
        return

    # Strip mention + prefix from content
    content = msg.content
    if client.user is not None:
        content = content.replace(f"<@{client.user.id}>", "")
        content = content.replace(f"<@!{client.user.id}>", "")
    content = PREFIX_RE.sub("", content).strip()

    # ── Special commands ─────────────────────────────────────────────────
    if content.lower() in ("/forget", "/reset", "/clear", "ลืม", "เคลียร์"):
        try:
            _hist_path(msg.channel.id).unlink(missing_ok=True)
        except Exception:
            pass
        await msg.reply("✅ ลืม conversation นี้แล้วครับ — เริ่มใหม่ได้เลย")
        return

    if not content:
        await msg.reply("ส่งคำถามหรือ task มาได้เลยครับ — เช่น `!sg list files in ~/Downloads`\n*Tip: พิมพ์ `/forget` เพื่อล้าง context*")
        return

    log.info("← %s [%s]: %.80s", msg.author, "DM" if is_dm else "ch", content)

    # ── Build prompt with channel history (so bot remembers context) ────────
    channel_id = msg.channel.id
    history = load_history(channel_id)
    full_prompt = build_prompt_with_history(content, history)

    async with msg.channel.typing():
        try:
            output, rc = await call_surrogate(full_prompt)
        except Exception as e:
            log.exception("surrogate call failed")
            await msg.reply(f"❌ internal error: `{type(e).__name__}: {e}`")
            return

    # ── Persist this turn so next message has context ───────────────────────
    history.append({"role": "user", "text": content})
    history.append({"role": "assistant", "text": output[:1500]})
    save_history(channel_id, history)

    # Prepare reply (chunk if >1900 chars)
    chunks = chunk(output, DISCORD_MAX)
    log.info("→ rc=%d, %d chars (%d chunks)", rc, len(output), len(chunks))

    for i, c in enumerate(chunks):
        prefix = "" if i == 0 else f"…(part {i+1}/{len(chunks)})\n"
        try:
            if i == 0:
                await msg.reply(prefix + c, mention_author=False)
            else:
                await msg.channel.send(prefix + c)
        except discord.HTTPException as e:
            log.warning("reply chunk %d failed: %s", i, e)
            break


# ── Run ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info("starting Hermes Discord bot")
    try:
        client.run(TOKEN, log_handler=None)  # use our file logger
    except KeyboardInterrupt:
        log.info("shutdown by signal")
    except Exception as e:
        log.exception("bot crashed: %s", e)
        raise
