# Hermes on Hugging Face Spaces (CPU 16 GB)
# Single-container that runs Ollama + Redis + all Hermes daemons.
FROM python:3.12-slim

# ── System deps ──────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl wget git ca-certificates jq sqlite3 redis-server \
    ripgrep fswatch procps net-tools zstd \
    && rm -rf /var/lib/apt/lists/*

# ── Ollama (CPU build for ARM/x86) ──────────────────────────────────────────
RUN curl -fsSL https://ollama.com/install.sh | sh

# ── App user (HF Spaces requires uid 1000) ──────────────────────────────────
RUN useradd -m -u 1000 hermes
ENV HOME=/home/hermes \
    PATH=/home/hermes/.local/bin:/usr/local/bin:/usr/bin:/bin \
    HERMES_HOME=/home/hermes/.hermes \
    PYTHONUNBUFFERED=1

WORKDIR /home/hermes

# ── Python deps for Hermes Discord bot + scrape + RAG ───────────────────────
COPY --chown=hermes:hermes requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# ── Copy Hermes scripts + config skeleton ───────────────────────────────────
COPY --chown=hermes:hermes bin/ /home/hermes/.claude/bin/
COPY --chown=hermes:hermes config/ /home/hermes/.hermes/config/
COPY --chown=hermes:hermes start.sh /home/hermes/start.sh
# start.sh orchestrates everything (Redis + Ollama + daemons + status server) — no supervisord needed
RUN chmod +x /home/hermes/.claude/bin/*.sh /home/hermes/start.sh

USER hermes

# ── Persistent dirs (HF mounts /data) ────────────────────────────────────────
RUN mkdir -p /home/hermes/.claude/state /home/hermes/.claude/logs \
    /home/hermes/.surrogate /home/hermes/.hermes/workspace \
    /home/hermes/.ollama

# ── Expose port 7860 (HF default) ────────────────────────────────────────────
EXPOSE 7860

# Run supervisord — manages ollama + redis + all hermes daemons
CMD ["/home/hermes/start.sh"]
