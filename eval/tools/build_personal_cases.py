"""Build eval cases from the author's own typing, recorded in TabType's local log.

Local only: reads ~/Library/Logs/TabType/tabtype.log, writes eval/private/ (gitignored).
Each v1 "predict full prompt" block holds the typed text so far ("Input:") and
the screen context at that moment. Consecutive prompts in one app that extend
each other are one message; its last version is what the author really wrote.
Cases split each message at word boundaries and mid-word, with the context
the author saw when typing that point.
"""
import json, re, sys, random
from pathlib import Path

LOG = Path.home() / "Library/Logs/TabType/tabtype.log"
OUT = Path(__file__).resolve().parent.parent / "private" / "personal-v1.jsonl"
CHAT = {"com.tinyspeck.slackmacgap": "Slack", "net.whatsapp.WhatsApp": "WhatsApp", "com.anthropic.claudefordesktop": "Claude",
        "com.microsoft.teams2": "Teams", "ru.keepcoder.Telegram": "Telegram", "com.apple.MobileSMS": "Messages",
        "com.hnc.Discord": "Discord", "org.whispersystems.signal-desktop": "Signal"}
NAMES = {"com.google.Chrome": "Google Chrome", "com.apple.Safari": "Safari", "com.apple.mail": "Mail",
         "com.apple.Notes": "Notes", "com.microsoft.VSCode": "Visual Studio Code", "com.apple.TextEdit": "TextEdit",
         "notion.id": "Notion", "com.microsoft.Outlook": "Outlook"}

lines = LOG.read_text(errors="replace").split("\n")
blocks = []          # (app_bundle, typed, context)
app = None
i = 0
while i < len(lines):
    line = lines[i]
    m = re.search(r"predict app=(\S+)", line)
    if m: app = m.group(1)
    if line.endswith("predict full prompt:"):
        j = i + 1
        body = []
        while j < len(lines) and j < i + 400:
            body.append(lines[j])
            if lines[j].startswith("Output:"): break
            j += 1
        text = "\n".join(body)
        inp = re.search(r"\nInput: (.*?)\nOutput:", text, re.S)
        if inp and app:
            ctx = ""
            for tag in ("recent_messages", "conversation", "on_screen"):
                c = re.search(rf"<{tag}[^>]*>\n?(.*?)\n?</{tag}>", text, re.S)
                if c: ctx += c.group(1).strip() + "\n"
            blocks.append((app, inp.group(1), ctx.strip()))
        i = j
    i += 1

# Messages: a run of prompts in one app where each typed text extends (or
# edits within) the previous one; the longest is the final message.
messages = []
cur = None
for app, typed, ctx in blocks:
    if cur and cur["app"] == app and (typed.startswith(cur["text"][: max(0, len(cur["text"]) - 12)]) or cur["text"].startswith(typed[:20])):
        if len(typed) >= len(cur["text"]):
            cur["text"] = typed
        cur["snaps"].append((typed, ctx))
    else:
        if cur: messages.append(cur)
        cur = {"app": app, "text": typed, "snaps": [(typed, ctx)]}
if cur: messages.append(cur)

def prose(t):
    words = re.findall(r"[A-Za-z]+", t)
    if len(words) < 5: return False
    letters = sum(c.isalpha() or c == " " for c in t)
    if letters / max(1, len(t)) < 0.8: return False
    if re.search(r"https?://|[{}<>=;]|\w+\(\)|\$ |\bnpm\b|\bgit\b", t): return False
    return True

seen, cases = set(), []
random.seed(7)
for n, msg in enumerate(messages):
    text = msg["text"].split("\n")[-1].strip() if "\n" in msg["text"] else msg["text"].strip()
    if len(text) < 25 or not prose(text) or text.lower() in seen: continue
    seen.add(text.lower())
    app = msg["app"]
    category = "chat" if app in CHAT else ("email" if app in ("com.apple.mail", "com.microsoft.Outlook") else "doc")
    name = CHAT.get(app) or NAMES.get(app) or app.split(".")[-1]
    # context: the snapshot whose typed text is closest to (but not past) the split
    def context_at(k):
        best = ""
        for typed, ctx in msg["snaps"]:
            if len(typed) <= k: best = ctx or best
        return best or (msg["snaps"][0][1] if msg["snaps"] else "")
    bounds = [m.end() for m in re.finditer(r" ", text) if 8 <= m.end() <= len(text) - 4]
    mids = [m.start() + 2 for m in re.finditer(r"\b[A-Za-z]{4,}", text) if 8 <= m.start() + 2 < len(text) - 3]
    picks = [("boundary", k) for k in random.sample(bounds, min(3, len(bounds)))] + \
            [("midword", k) for k in random.sample(mids, min(2, len(mids)))]
    for kind, k in picks:
        before = msg["text"][: msg["text"].rfind(text)] + text[:k] if text in msg["text"] else text[:k]
        cases.append({"id": f"{n}-{kind}-{k}", "category": category, "app": name, "kind": kind,
                      "context": context_at(len(before)), "prefix": before[-2000:], "truth": text[k:k + 80]})

OUT.write_text("\n".join(json.dumps(c, ensure_ascii=False) for c in cases) + "\n")
from collections import Counter
print(f"{len(blocks)} prompts → {len(messages)} messages → {len(seen)} prose messages → {len(cases)} cases")
print(Counter(c["category"] for c in cases), Counter(c["app"] for c in cases).most_common(8))

# --export-writing <path>: the same messages as {"bundleId", "text"} lines, for
# TabType's one-time import into "Learn from your writing" (encrypted there).
if "--export-writing" in sys.argv:
    path = Path(sys.argv[sys.argv.index("--export-writing") + 1])
    seen_export, rows = set(), []
    for msg in messages:
        text = msg["text"].strip()
        if len(text) < 20 or not prose(text) or text.lower() in seen_export: continue
        seen_export.add(text.lower())
        rows.append(json.dumps({"bundleId": msg["app"], "text": text}, ensure_ascii=False))
    path.write_text("\n".join(rows) + "\n")
    print(f"exported {len(rows)} messages → {path}")
