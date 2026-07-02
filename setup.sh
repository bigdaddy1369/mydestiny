#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# My Destiny - setup script (FIXED)
# ---------------------------------------------------------------------------

mkdir -p ~/MyDestiny
cd ~/MyDestiny

# --- OS / package manager check ---------------------------------------------
if command -v apt >/dev/null 2>&1; then
  sudo apt update
  sudo apt install -y python3 python3-venv python3-pip curl
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y python3 python3-pip curl
elif command -v pacman >/dev/null 2>&1; then
  sudo pacman -Sy --noconfirm python python-pip curl
elif command -v brew >/dev/null 2>&1; then
  brew install python3 curl
else
  echo "ERROR: No supported package manager found (apt/dnf/pacman/brew)." >&2
  echo "Please install python3, python3-venv, pip, and curl manually, then re-run this script." >&2
  exit 1
fi

# Verify Python 3.8+
PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 8 ]); then
  echo "ERROR: Python 3.8+ required. Found Python $PYTHON_VERSION" >&2
  exit 1
fi

echo "✓ Python $PYTHON_VERSION detected"

# --- Ollama install ----------------------------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
  echo "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  echo "✓ Ollama installed"
else
  echo "✓ Ollama already installed"
fi

# Make sure the Ollama daemon is actually up before we try to pull a model.
echo "Waiting for Ollama server..."
MAX_ATTEMPTS=30
ATTEMPT=0

if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "Starting Ollama server..."
  nohup ollama serve > ollama.log 2>&1 &
  OLLAMA_PID=$!
  
  # Wait up to 30s for it to come alive
  while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    if curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
      echo "✓ Ollama server started"
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
  done
  
  if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "ERROR: Ollama server did not start after 30 seconds." >&2
    echo "Check ollama.log for details:" >&2
    tail -20 ollama.log >&2
    exit 1
  fi
else
  echo "✓ Ollama server already running"
fi

echo "Pulling llama3.2:1b model (this may take a few minutes)..."
ollama pull llama3.2:1b
echo "✓ Model ready"

# --- Python environment -------------------------------------------------------
if [ ! -d ".venv" ]; then
  echo "Creating Python virtual environment..."
  python3 -m venv .venv
fi

source .venv/bin/activate

echo "Installing dependencies..."
pip install --upgrade pip >/dev/null 2>&1
pip install flask==3.0.3 requests==2.32.3 >/dev/null 2>&1
echo "✓ Dependencies installed"

mkdir -p src data books assets plugins

cat > src/app.py <<'PY'
from flask import Flask, request, jsonify, render_template_string, Response, stream_with_context
import sqlite3
import requests
import os
import re
import json
import datetime

APP_NAME = "My Destiny"
DB_PATH = "data/mydestiny.db"
OLLAMA_URL = "http://localhost:11434/api/chat"
MODEL = "llama3.2:1b"
HISTORY_TURNS = 10  # how many past user/AI exchanges to feed back as context

app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html>
<head>
<title>My Destiny</title>
<style>
body { margin:0; background:#12091f; color:white; font-family:Arial; }
.app { display:flex; height:100vh; }
.sidebar { width:230px; background:#0b0614; padding:20px; }
.sidebar h1 { color:#d8b4fe; }
.sidebar button { width:100%; margin:8px 0; padding:12px; background:#241236; color:white; border:0; cursor:pointer; }
.main { flex:1; padding:25px; background:linear-gradient(#241236,#12091f); position:relative; }
.panel { background:#111827; border:2px solid #9333ea; padding:15px; border-radius:12px; margin-bottom:15px; }
textarea { width:95%; height:120px; padding:10px; font-size:16px; }
input { padding:10px; font-size:16px; width:70%; }
button { padding:10px; background:#9333ea; color:white; border:0; cursor:pointer; }
.avatar { position:absolute; right:80px; bottom:90px; text-align:center; animation: floatBob 3s ease-in-out infinite; }
.head { width:90px; height:90px; background:#f2b28d; border-radius:50%; margin:auto; position:relative; transition: box-shadow 0.4s ease; }
.hair { width:100px; height:45px; background:#2b160f; border-radius:50px 50px 0 0; position:absolute; top:-8px; left:-5px; }
.eye { width:8px; height:8px; background:black; border-radius:50%; position:absolute; top:42px; animation: blinkEye 6s infinite; }
.left { left:28px; } .right { right:28px; animation-delay: 0.2s; }
.mouth { position:absolute; bottom:20px; left:34px; width:22px; border-bottom:3px solid red; transition: all 0.25s ease; }
.body { width:100px; height:150px; background:#111827; margin:auto; border-radius:20px; }
.desk { position:absolute; right:40px; bottom:25px; width:250px; height:70px; background:#5b3a29; border-radius:10px; text-align:center; line-height:70px; }

@keyframes floatBob { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-8px); } }
@keyframes blinkEye { 0%, 90%, 100% { transform: scaleY(1); } 95% { transform: scaleY(0.1); } }
@keyframes talkMouth { 0%, 100% { height:3px; width:22px; } 50% { height:14px; width:16px; } }

.mood-dot { display:inline-block; width:8px; height:8px; border-radius:50%; background:#9ca3af; margin-left:8px; vertical-align:middle; }
.mood-label { font-size:12px; opacity:0.7; text-transform:capitalize; }

.avatar.mood-thinking .head { box-shadow: 0 0 16px 5px rgba(251,191,36,0.55); }
.avatar.mood-talking .head { box-shadow: 0 0 16px 5px rgba(168,85,247,0.55); }
.avatar.mood-happy .head { box-shadow: 0 0 16px 5px rgba(74,222,128,0.55); }
.avatar.mood-error .head { box-shadow: 0 0 16px 5px rgba(248,113,113,0.55); }
.avatar.mood-writing .head { box-shadow: 0 0 16px 5px rgba(96,165,250,0.55); }

.avatar.mood-talking .mouth { animation: talkMouth 0.35s infinite; border-bottom-color:#d8b4fe; }
.avatar.mood-happy .mouth { width:26px; height:10px; border:none; border-bottom:3px solid #4ade80; border-radius:0 0 14px 14px; }
.avatar.mood-error .mouth { width:24px; height:10px; border:none; border-bottom:3px solid #f87171; border-radius:0 0 14px 14px; transform: scaleY(-1); }
.avatar.mood-thinking .mouth { width:10px; height:10px; border:2px solid #fbbf24; border-radius:50%; }
.avatar.mood-writing .mouth { border-bottom-color:#60a5fa; }

.book-row { display:flex; gap:8px; align-items:center; flex-wrap:wrap; margin-bottom:10px; }
.book-row select { padding:10px; font-size:14px; background:#241236; color:white; border:0; border-radius:4px; }
#book_preview { max-height:220px; overflow-y:auto; background:#0b0614; padding:10px; border-radius:8px; white-space:pre-wrap; font-size:13px; }
</style>
</head>
<body>
<div class="app">
  <div class="sidebar">
    <h1>My Destiny</h1>
    <button onclick="show('chat')">AI Chat</button>
    <button onclick="show('book')">Book Studio</button>
    <button onclick="show('memory')">Memory</button>
    <button onclick="greet()">Companion</button>
  </div>

  <div class="main">
    <h2>My Destiny Genesis 0.1</h2>

    <div class="panel">
      <b>Companion:</b>
      <span class="mood-dot" id="mood_dot"></span><span class="mood-label" id="mood_label">idle</span>
      <p id="bubble">Hi, I am your My Destiny companion.</p>
    </div>

    <div id="chat" class="panel">
      <h3>AI Chat</h3>
      <input id="message" placeholder="Talk to My Destiny..." />
      <button onclick="chat()">Send</button>
      <p id="reply"></p>
    </div>

    <div id="book" class="panel" style="display:none;">
      <h3>Book Studio</h3>
      <div class="book-row">
        <select id="book_select" onchange="loadSelectedBook()">
          <option value="">-- New Book --</option>
        </select>
        <button onclick="loadBookList()">Refresh</button>
        <button onclick="exportBook()">Export .txt</button>
      </div>
      <input id="book_title" placeholder="Book title" />
      <br><br>
      <textarea id="chapter" placeholder="Write your next chapter here..."></textarea>
      <br>
      <button onclick="saveBook()">Save Chapter</button>
      <button onclick="generateChapter()">AI Continue Chapter</button>
      <p id="book_status"></p>
      <h3 style="margin-bottom:6px;">Previous Chapters</h3>
      <pre id="book_preview">No chapters loaded yet.</pre>
    </div>

    <div id="memory" class="panel" style="display:none;">
      <h3>Memory</h3>
      <p style="opacity:0.7;font-size:14px;">My Destiny automatically recalls your last 10 exchanges in every chat reply.</p>
      <button onclick="loadMemory()">Load Recent Memory</button>
      <button onclick="clearMemory()" style="background:#7f1d1d;">Clear Memory</button>
      <pre id="memory_box"></pre>
    </div>

    <div class="avatar mood-idle">
      <div class="head">
        <div class="hair"></div>
        <div class="eye left"></div>
        <div class="eye right"></div>
        <div class="mouth"></div>
      </div>
      <div class="body"></div>
    </div>
    <div class="desk">Desk</div>
  </div>
</div>

<script>
function show(id) {
  document.getElementById("chat").style.display = "none";
  document.getElementById("book").style.display = "none";
  document.getElementById("memory").style.display = "none";
  document.getElementById(id).style.display = "block";
  if (id === "book") loadBookList();
}

function talk(text) {
  document.getElementById("bubble").innerText = text;
}

const MOOD_COLORS = {
  idle: "#9ca3af",
  thinking: "#fbbf24",
  talking: "#a855f7",
  happy: "#4ade80",
  error: "#f87171",
  writing: "#60a5fa"
};

function setMood(mood) {
  document.querySelector(".avatar").className = "avatar mood-" + mood;
  document.getElementById("mood_dot").style.background = MOOD_COLORS[mood] || MOOD_COLORS.idle;
  document.getElementById("mood_label").innerText = mood;
}

function greet() {
  setMood("happy");
  talk("Companion mode active. I'm here to help!");
  setTimeout(() => setMood("idle"), 2500);
}

async function streamChat(message, onChunk) {
  let res = await fetch("/api/chat/stream", {
    method:"POST",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({message:message})
  });

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let fullText = "";

  while (true) {
    const {done, value} = await reader.read();
    if (done) break;
    fullText += decoder.decode(value, {stream:true});
    onChunk(fullText);
  }
  return fullText;
}

async function chat() {
  let msg = document.getElementById("message").value;
  if (!msg.trim()) return;
  document.getElementById("message").value = "";
  document.getElementById("reply").innerText = "";
  setMood("thinking");
  talk("Thinking...");

  let started = false;
  let fullText = await streamChat(msg, (text) => {
    if (!started) { setMood("talking"); started = true; }
    talk(text);
    document.getElementById("reply").innerText = text;
  });

  if (!fullText) {
    setMood("error");
    talk("I could not answer.");
  } else if (fullText.startsWith("AI error")) {
    setMood("error");
  } else {
    setMood("happy");
    setTimeout(() => setMood("idle"), 2000);
  }
}

async function loadBookList() {
  let res = await fetch("/api/book/list");
  let data = await res.json();
  let select = document.getElementById("book_select");
  let current = select.value;
  select.innerHTML = '<option value="">-- New Book --</option>';
  data.books.forEach(b => {
    let opt = document.createElement("option");
    opt.value = b.title;
    opt.textContent = b.title + " (" + b.chapters + " ch.)";
    select.appendChild(opt);
  });
  select.value = current || "";
}

async function loadSelectedBook() {
  let title = document.getElementById("book_select").value;
  document.getElementById("book_title").value = title;
  document.getElementById("chapter").value = "";

  if (!title) {
    document.getElementById("book_status").innerText = "Starting a new book.";
    document.getElementById("book_preview").innerText = "No chapters loaded yet.";
    return;
  }

  let res = await fetch("/api/book/load?title=" + encodeURIComponent(title));
  let data = await res.json();
  document.getElementById("book_status").innerText =
    data.chapters.length + " chapter(s) loaded. Write chapter " + (data.chapters.length + 1) + " below.";
  document.getElementById("book_preview").innerText = data.chapters.length
    ? data.chapters.map((c, i) => "--- Chapter " + c.chapter_number + " ---\\n" + c.text).join("\\n\\n")
    : "No chapters loaded yet.";
}

async function saveBook() {
  let title = document.getElementById("book_title").value.trim();
  let chapter = document.getElementById("chapter").value;

  if (!title) {
    document.getElementById("book_status").innerText = "Please enter a book title first.";
    return;
  }
  if (!chapter.trim()) {
    document.getElementById("book_status").innerText = "Write something before saving.";
    return;
  }

  let res = await fetch("/api/book/save", {
    method:"POST",
    headers:{"Content-Type":"application/json"},
    body:JSON.stringify({title:title, chapter:chapter})
  });

  let data = await res.json();
  document.getElementById("book_status").innerText = data.status + " (Chapter " + data.chapter_number + ")";
  document.getElementById("chapter").value = "";
  setMood("happy");
  talk('Saved chapter ' + data.chapter_number + ' of "' + title + '."');
  setTimeout(() => setMood("idle"), 2000);

  await loadBookList();
  document.getElementById("book_select").value = title;
  await loadSelectedBook();
}

async function generateChapter() {
  let title = document.getElementById("book_title").value.trim();
  let chapter = document.getElementById("chapter").value;
  setMood("writing");
  talk("Writing...");

  let context = "";
  if (title) {
    try {
      let res = await fetch("/api/book/load?title=" + encodeURIComponent(title));
      let data = await res.json();
      if (data.chapters && data.chapters.length) {
        let last = data.chapters[data.chapters.length - 1];
        context = "For continuity, here is the previous chapter (Chapter " + last.chapter_number + "):\\n" + last.text + "\\n\\n";
      }
    } catch (e) {
      // no previous chapters available, continue without context
    }
  }

  let fullText = await streamChat(context + "Continue this new chapter:\\n\\n" + chapter, (text) => {
    document.getElementById("chapter").value = chapter + "\\n\\n" + text;
  });

  if (fullText && fullText.startsWith("AI error")) {
    setMood("error");
    talk("Something went wrong while writing.");
  } else {
    setMood("happy");
    talk("I added more to your chapter.");
    setTimeout(() => setMood("idle"), 2000);
  }
}

function exportBook() {
  let title = document.getElementById("book_title").value.trim();
  if (!title) {
    document.getElementById("book_status").innerText = "Select or name a book first.";
    return;
  }
  window.location = "/api/book/export?title=" + encodeURIComponent(title);
}

async function loadMemory() {
  let res = await fetch("/api/memory");
  let data = await res.json();
  document.getElementById("memory_box").innerText = data.memory.length
    ? data.memory.join("\\n\\n")
    : "No memory yet — start chatting.";
}

async function clearMemory() {
  let res = await fetch("/api/memory/clear", { method: "POST" });
  let data = await res.json();
  document.getElementById("memory_box").innerText = "";
  talk(data.status);
}

setMood("idle");
</script>
</body>
</html>
"""

def init_db():
    os.makedirs("data", exist_ok=True)
    os.makedirs("books", exist_ok=True)

    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()

    cur.execute("""
    CREATE TABLE IF NOT EXISTS conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_message TEXT,
        ai_reply TEXT,
        created_at TEXT
    )
    """)

    cur.execute("""
    CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT,
        chapter TEXT,
        chapter_number INTEGER DEFAULT 1,
        created_at TEXT
    )
    """)

    # Migration: adds chapter_number to DBs created by an older version
    try:
        cur.execute("ALTER TABLE books ADD COLUMN chapter_number INTEGER DEFAULT 1")
    except sqlite3.OperationalError:
        pass  # column already exists

    con.commit()
    con.close()

def save_chat(user_message, ai_reply):
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute(
        "INSERT INTO conversations (user_message, ai_reply, created_at) VALUES (?, ?, ?)",
        (user_message, ai_reply, datetime.datetime.now().isoformat())
    )
    con.commit()
    con.close()

def get_recent_history(limit=HISTORY_TURNS):
    """Return the last `limit` user/AI exchanges as chat-style messages, oldest first."""
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute(
        "SELECT user_message, ai_reply FROM conversations ORDER BY id DESC LIMIT ?",
        (limit,)
    )
    rows = cur.fetchall()
    con.close()

    rows.reverse()  # oldest first
    messages = []
    for user_message, ai_reply in rows:
        messages.append({"role": "user", "content": user_message})
        messages.append({"role": "assistant", "content": ai_reply})
    return messages

def ask_ai_stream(message):
    """Yield reply text incrementally as Ollama generates it."""
    history = get_recent_history()

    payload = {
        "model": MODEL,
        "stream": True,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are My Destiny, a helpful AI desktop companion. You help with "
                    "books, coding, research, work, notes, and creative projects. "
                    "Use the conversation history to remember context and stay consistent."
                )
            },
            *history,
            {"role": "user", "content": message}
        ]
    }

    try:
        with requests.post(OLLAMA_URL, json=payload, stream=True, timeout=120) as r:
            r.raise_for_status()
            for line in r.iter_lines():
                if not line:
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue
                chunk = data.get("message", {}).get("content", "")
                if chunk:
                    yield chunk
                if data.get("done"):
                    break
    except requests.exceptions.ConnectionError:
        yield "AI error. Make sure Ollama is running with: ollama serve"
    except requests.exceptions.Timeout:
        yield "AI error. The request timed out - try a shorter message."
    except Exception as e:
        yield f"AI error: {e}"

def ask_ai(message):
    history = get_recent_history()

    payload = {
        "model": MODEL,
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You are My Destiny, a helpful AI desktop companion. You help with "
                    "books, coding, research, work, notes, and creative projects. "
                    "Use the conversation history to remember context and stay consistent."
                )
            },
            *history,
            {"role": "user", "content": message}
        ]
    }

    try:
        r = requests.post(OLLAMA_URL, json=payload, timeout=120)
        r.raise_for_status()
        data = r.json()
        return data.get("message", {}).get("content", "I could not answer.")
    except requests.exceptions.ConnectionError:
        return "AI error. Make sure Ollama is running with: ollama serve"
    except requests.exceptions.Timeout:
        return "AI error. The request timed out — try a shorter message."
    except Exception as e:
        return f"AI error: {e}"

def safe_filename(title):
    """Turn a user-supplied title into a safe filename component."""
    title = (title or "Untitled_Book").strip() or "Untitled_Book"
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "_", title)
    cleaned = cleaned.strip("._") or "Untitled_Book"
    return cleaned[:100]

@app.route("/")
def home():
    return render_template_string(HTML)

@app.route("/api/chat", methods=["POST"])
def api_chat():
    body = request.get_json(silent=True) or {}
    message = (body.get("message") or "").strip()
    if not message:
        return jsonify({"reply": "Please enter a message."}), 400
    reply = ask_ai(message)
    save_chat(message, reply)
    return jsonify({"reply": reply})

@app.route("/api/chat/stream", methods=["POST"])
def api_chat_stream():
    body = request.get_json(silent=True) or {}
    message = (body.get("message") or "").strip()
    if not message:
        return jsonify({"reply": "Please enter a message."}), 400

    def generate():
        full_reply = []
        for chunk in ask_ai_stream(message):
            full_reply.append(chunk)
            yield chunk
        save_chat(message, "".join(full_reply))

    return Response(stream_with_context(generate()), mimetype="text/plain")

@app.route("/api/memory")
def api_memory():
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("SELECT user_message, ai_reply FROM conversations ORDER BY id DESC LIMIT 10")
    rows = cur.fetchall()
    con.close()

    memory = [f"You: {u}\nMy Destiny: {a}" for u, a in rows]
    return jsonify({"memory": memory})

@app.route("/api/memory/clear", methods=["POST"])
def api_memory_clear():
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("DELETE FROM conversations")
    con.commit()
    con.close()
    return jsonify({"status": "Memory cleared."})

@app.route("/api/book/save", methods=["POST"])
def api_book_save():
    body = request.get_json(silent=True) or {}
    title = (body.get("title") or "Untitled Book").strip() or "Untitled Book"
    chapter = body.get("chapter") or ""

    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("SELECT COALESCE(MAX(chapter_number), 0) FROM books WHERE title = ?", (title,))
    chapter_number = cur.fetchone()[0] + 1

    cur.execute(
        "INSERT INTO books (title, chapter, chapter_number, created_at) VALUES (?, ?, ?, ?)",
        (title, chapter, chapter_number, datetime.datetime.now().isoformat())
    )
    con.commit()
    con.close()

    safe_title = safe_filename(title)
    with open(f"books/{safe_title}.txt", "a", encoding="utf-8") as f:
        f.write(f"\n\n--- Chapter {chapter_number} ---\n")
        f.write(chapter)

    return jsonify({"status": "Chapter saved.", "chapter_number": chapter_number, "title": title})

@app.route("/api/book/list")
def api_book_list():
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("""
        SELECT title, COUNT(*) as chapters, MAX(created_at) as updated
        FROM books
        GROUP BY title
        ORDER BY updated DESC
    """)
    rows = cur.fetchall()
    con.close()

    books = [{"title": t, "chapters": c, "updated": u} for t, c, u in rows]
    return jsonify({"books": books})

@app.route("/api/book/load")
def api_book_load():
    title = request.args.get("title", "").strip()
    if not title:
        return jsonify({"title": "", "chapters": []})

    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute(
        "SELECT chapter, chapter_number FROM books WHERE title = ? ORDER BY chapter_number ASC",
        (title,)
    )
    rows = cur.fetchall()
    con.close()

    chapters = [{"chapter_number": n, "text": t} for t, n in rows]
    return jsonify({"title": title, "chapters": chapters})

@app.route("/api/book/export")
def api_book_export():
    title = request.args.get("title", "").strip()
    if not title:
        return jsonify({"error": "No title given."}), 400

    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute(
        "SELECT chapter, chapter_number FROM books WHERE title = ? ORDER BY chapter_number ASC",
        (title,)
    )
    rows = cur.fetchall()
    con.close()

    if not rows:
        return jsonify({"error": "No chapters found for that title."}), 404

    parts = [f"{title}\n{'=' * len(title)}\n"]
    for chapter_text, chapter_number in rows:
        parts.append(f"\n\n--- Chapter {chapter_number} ---\n\n{chapter_text}")
    full_text = "".join(parts)

    filename = safe_filename(title) + ".txt"
    return Response(
        full_text,
        mimetype="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'}
    )

if __name__ == "__main__":
    init_db()
    print("My Destiny is running at http://localhost:8080")
    app.run(host="127.0.0.1", port=8080, threaded=True)
PY

cat > launcher.sh <<'LAUNCH_EOF'
#!/bin/bash
set -euo pipefail
cd ~/MyDestiny
source .venv/bin/activate

echo "My Destiny Launcher"
echo "==================="

# Make sure Ollama is running before launching
if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "Starting Ollama server..."
  nohup ollama serve > ollama.log 2>&1 &
  sleep 3
  
  # Verify it started
  if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "ERROR: Ollama failed to start. Check ollama.log"
    exit 1
  fi
fi

echo "✓ Ollama ready"

# Check if port 8080 is available
if command -v lsof >/dev/null 2>&1 && lsof -i :8080 >/dev/null 2>&1; then
  echo "WARNING: Port 8080 is already in use. App may fail to start." >&2
fi

echo ""
echo "Launching My Destiny at http://localhost:8080"
echo "Press Ctrl+C to stop."
echo ""

python3 src/app.py
LAUNCH_EOF

chmod +x launcher.sh

echo ""
echo "✓ Setup complete!"
echo ""
echo "To launch My Destiny:"
echo "  cd ~/MyDestiny && ./launcher.sh"
echo ""
echo "Then open http://localhost:8080 in your browser."
