#!/usr/bin/env bash
# ... (original content unchanged)
# Sync Obsidian markdown patterns/knowledge → FalkorDB Lite (graph DB)
# Complements rag-index.sh (vector DB) — same sources, 2 different indexes.
set -e
PYTHON="${HOME}/.surrogate/venv/bin/python"
[ -x "$PYTHON" ] || { echo "venv not found: $PYTHON"; exit 1; }

"$PYTHON" <<'PY'
import re, os
from pathlib import Path
from redislite.falkordb_client import FalkorDB
import yaml

HOME = Path.home()
SOURCES = [
    HOME / "Documents/Obsidian Vault/AI-Hub/patterns",
    HOME / "Documents/Obsidian Vault/AI-Hub/knowledge",
    HOME / "Documents/Obsidian Vault/AI-Hub/inbox",
    HOME / ".surrogate/memory",
]
DB_FILE = str(HOME / ".surrogate/graph-db.rdb")

db = FalkorDB(dbfilename=DB_FILE)
g = db.select_graph("ashira")

try: g.query("MATCH (n) DETACH DELETE n")
except: pass

frontmatter_re = re.compile(r'^---\n(.*?)\n---', re.DOTALL)
wikilink_re = re.compile(r'\[\[([^\]|]+?)(?:\|[^\]]+)?\]\]')

def esc(s):
    return str(s).replace("\\", "\\\\").replace("'", "\\'") if s else ""

nodes = {}
edges = []

for src in SOURCES:
    if not src.exists(): continue
    for md in src.rglob("*.md"):
        stem = md.stem
        text = md.read_text(errors="ignore")
        fm_match = frontmatter_re.match(text)
        fm = {}
        if fm_match:
            try: fm = yaml.safe_load(fm_match.group(1)) or {}
            except: pass

        tags = fm.get("tags", [])
        if isinstance(tags, str): tags = [tags]

        nodes[stem] = {
            "path": str(md.relative_to(HOME)),
            "tags": [str(t).replace("#","") for t in tags],
            "category": md.parent.name,
            "severity": str(fm.get("severity", "medium")),
        }

        for link in wikilink_re.findall(text):
            target = link.split("/")[-1].split("|")[0].replace(".md", "").strip()
            if target and target != stem:
                edges.append((stem, target))

for name, info in nodes.items():
    g.query(
        f"MERGE (n:Doc {{name:'{esc(name)}'}}) "
        f"SET n.path='{esc(info['path'])}', "
        f"n.category='{esc(info['category'])}', "
        f"n.severity='{esc(info['severity'])}', "
        f"n.tags='{esc(','.join(info['tags']))}'"
    )

edge_count = 0
for src_name, tgt_name in edges:
    try:
        g.query(
            f"MATCH (a:Doc {{name:'{esc(src_name)}'}}), (b:Doc {{name:'{esc(tgt_name)}'}}) "
            f"MERGE (a)-[:LINKS_TO]->(b)"
        )
        edge_count += 1
    except: pass

all_tags = set()
for info in nodes.values():
    for t in info["tags"]:
        if t: all_tags.add(t)
for t in all_tags:
    g.query(f"MERGE (:Tag {{name:'{esc(t)}'}})")
for name, info in nodes.items():
    for t in info["tags"]:
        if not t: continue
        g.query(
            f"MATCH (d:Doc {{name:'{esc(name)}'}}), (t:Tag {{name:'{esc(t)}'}}) "
            f"MERGE (d)-[:TAGGED]->(t)"
        )

print(f"Graph built: {len(nodes)} docs, {edge_count} links, {len(all_tags)} tags")

r = g.query("MATCH (d:Doc)-[:TAGGED]->(t:Tag) RETURN t.name, count(d) AS c ORDER BY c DESC LIMIT 10")
print("\nTop 10 tags:")
for row in r.result_set: print(f"  #{row[0]}: {row[1]} docs")

r = g.query("MATCH (d:Doc)-[r:LINKS_TO]-() RETURN d.name, count(r) AS c ORDER BY c DESC LIMIT 10")
print("\nTop 10 hubs (most connected):")
for row in r.result_set: print(f"  {row[0]}: {row[1]} links")
PY
