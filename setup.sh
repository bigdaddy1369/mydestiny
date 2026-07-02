#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# My Destiny - setup script (OPTIMIZED FOR SPEED)
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
  exit 1
fi

PYTHON_VERSION=$(python3 --version 2>&1 | awk '{print $2}')
PYTHON_MAJOR=$(echo $PYTHON_VERSION | cut -d. -f1)
PYTHON_MINOR=$(echo $PYTHON_VERSION | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 8 ]); then
  echo "ERROR: Python 3.8+ required. Found Python $PYTHON_VERSION" >&2
  exit 1
fi

echo "✓ Python $PYTHON_VERSION detected"

if ! command -v ollama >/dev/null 2>&1; then
  echo "Installing Ollama..."
  curl -fsSL https://ollama.com/install.sh | sh
  echo "✓ Ollama installed"
else
  echo "✓ Ollama already installed"
fi

echo "Waiting for Ollama server..."
MAX_ATTEMPTS=30
ATTEMPT=0

if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "Starting Ollama server..."
  nohup ollama serve > ollama.log 2>&1 &
  
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
    exit 1
  fi
else
  echo "✓ Ollama server already running"
fi

echo "Pulling mistral:latest (FASTEST model - ~4B params)..."
ollama pull mistral:latest
echo "✓ Model ready"

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
MODEL = "mistral:latest"
HISTORY_TURNS = 5

app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>My Destiny</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  min-height: 100vh;
  color: #333;
}
.container {
  display: flex;
  height: 100vh;
}
.sidebar {
  width: 280px;
  background: rgba(255,255,255,0.95);
  padding: 30px 20px;
  box-shadow: 2px 0 15px rgba(0,0,0,0.1);
  overflow-y: auto;
  border-right: 3px solid #667eea;
}
.sidebar h1 {
  font-size: 28px;
  color: #667eea;
  margin-bottom: 30px;
  text-align: center;
  font-weight: 700;
}
.sidebar button {
  width: 100%;
  padding: 12px 16px;
  margin: 10px 0;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  border: none;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.3s ease;
  box-shadow: 0 4px 15px rgba(102, 126, 234, 0.3);
}
.sidebar button:hover {
  transform: translateY(-2px);
  box-shadow: 0 6px 20px rgba(102, 126, 234, 0.4);
}
.sidebar button:active {
  transform: translateY(0);
}
.main {
  flex: 1;
  display: flex;
  flex-direction: column;
  background: white;
}
.header {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  padding: 25px 40px;
  box-shadow: 0 4px 15px rgba(0,0,0,0.1);
}
.header h2 {
  font-size: 28px;
  font-weight: 700;
  letter-spacing: 0.5px;
}
.header p {
  font-size: 12px;
  opacity: 0.9;
  margin-top: 5px;
}
.content {
  flex: 1;
  overflow-y: auto;
  padding: 30px 40px;
  display: flex;
  flex-direction: column;
}
.panel {
  background: #f8f9fb;
  border-radius: 12px;
  padding: 25px;
  margin-bottom: 20px;
  border: 1px solid #e8ebf0;
  box-shadow: 0 2px 8px rgba(0,0,0,0.05);
}
.chat-container {
  display: flex;
  flex-direction: column;
  gap: 12px;
  max-height: 400px;
  overflow-y: auto;
  margin-bottom: 15px;
}
.message {
  display: flex;
  margin: 8px 0;
  animation: slideIn 0.3s ease;
}
@keyframes slideIn {
  from { opacity: 0; transform: translateY(10px); }
  to { opacity: 1; transform: translateY(0); }
}
.message.user {
  justify-content: flex-end;
}
.message-bubble {
  max-width: 70%;
  padding: 12px 16px;
  border-radius: 18px;
  font-size: 14px;
  line-height: 1.5;
  word-wrap: break-word;
}
.message.user .message-bubble {
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  border-radius: 18px 4px 18px 18px;
}
.message.ai .message-bubble {
  background: white;
  color: #333;
  border: 2px solid #e8ebf0;
  border-radius: 4px 18px 18px 18px;
}
.input-group {
  display: flex;
  gap: 10px;
  margin-bottom: 15px;
}
input[type="text"], textarea {
  flex: 1;
  padding: 12px 16px;
  border: 2px solid #e8ebf0;
  border-radius: 8px;
  font-size: 14px;
  font-family: inherit;
  transition: all 0.3s ease;
}
input[type="text"]:focus, textarea:focus {
  outline: none;
  border-color: #667eea;
  box-shadow: 0 0 0 3px rgba(102, 126, 234, 0.1);
}
textarea {
  resize: vertical;
  min-height: 100px;
}
button {
  padding: 12px 24px;
  background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  color: white;
  border: none;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  transition: all 0.3s ease;
  box-shadow: 0 4px 15px rgba(102, 126, 234, 0.3);
}
button:hover {
  transform: translateY(-2px);
  box-shadow: 0 6px 20px rgba(102, 126, 234, 0.4);
}
button:active {
  transform: translateY(0);
}
.avatar-section {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 20px;
  margin-bottom: 20px;
}
.avatar {
  width: 120px;
  height: 140px;
  position: relative;
  display: flex;
  align-items: center;
  justify-content: center;
}
.face {
  width: 100px;
  height: 120px;
  background: linear-gradient(135deg, #fdbcb4 0%, #f2a679 100%);
  border-radius: 45px 45px 50px 50px;
  position: relative;
  box-shadow: 0 10px 30px rgba(0,0,0,0.2);
  display: flex;
  align-items: center;
  justify-content: center;
  flex-direction: column;
}
.eyes {
  display: flex;
  gap: 25px;
  margin-bottom: 15px;
}
.eye {
  width: 12px;
  height: 12px;
  background: #333;
  border-radius: 50%;
  position: relative;
  animation: blink 4s infinite;
}
@keyframes blink {
  0%, 90%, 100% { height: 12px; }
  95% { height: 2px; }
}
.pupil {
  width: 6px;
  height: 6px;
  background: #1a1a1a;
  border-radius: 50%;
  position: absolute;
  top: 3px;
  left: 3px;
}
.mouth {
  width: 20px;
  height: 8px;
  border: 2px solid #e74c3c;
  border-top: none;
  border-radius: 0 0 10px 10px;
  position: relative;
}
.avatar.mood-happy .mouth {
  background: #e74c3c;
  border: none;
  border-radius: 0 0 8px 8px;
}
.avatar.mood-thinking .mouth {
  width: 6px;
  height: 6px;
  border: 2px solid #f39c12;
  border-radius: 50%;
}
.avatar.mood-talking .mouth {
  animation: talk 0.3s infinite;
}
@keyframes talk {
  0%, 100% { height: 4px; }
  50% { height: 12px; }
}
.mood-indicator {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 15px;
}
.mood-dot {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  background: #bdc3c7;
}
.mood-dot.thinking { background: #f39c12; }
.mood-dot.talking { background: #667eea; }
.mood-dot.happy { background: #27ae60; }
.mood-dot.error { background: #e74c3c; }
.mood-dot.writing { background: #3498db; }
.mood-text {
  font-size: 12px;
  color: #666;
  font-weight: 600;
  text-transform: capitalize;
}
.bubble-text {
  font-size: 13px;
  color: #333;
  line-height: 1.6;
  max-width: 200px;
}
.book-controls {
  display: flex;
  gap: 10px;
  margin-bottom: 15px;
  flex-wrap: wrap;
}
.book-controls select {
  padding: 10px 14px;
  border: 2px solid #e8ebf0;
  border-radius: 8px;
  font-size: 13px;
  background: white;
  cursor: pointer;
}
select:focus {
  outline: none;
  border-color: #667eea;
}
.chapters-list {
  background: white;
  border: 1px solid #e8ebf0;
  border-radius: 8px;
  padding: 15px;
  max-height: 300px;
  overflow-y: auto;
  font-size: 13px;
  line-height: 1.6;
  color: #555;
  font-family: 'Courier New', monospace;
}
.section {
  display: none;
}
.section.active {
  display: block;
}
h3 {
  color: #667eea;
  font-size: 18px;
  margin-bottom: 15px;
  font-weight: 700;
}
.status-text {
  font-size: 12px;
  color: #666;
  margin-top: 10px;
  font-style: italic;
}
.loading {
  display: inline-block;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: #667eea;
  margin-left: 5px;
  animation: loading 1s infinite;
}
@keyframes loading {
  0%, 100% { opacity: 0.3; }
  50% { opacity: 1; }
}
::-webkit-scrollbar {
  width: 8px;
}
::-webkit-scrollbar-track {
  background: #f1f1f1;
  border-radius: 10px;
}
::-webkit-scrollbar-thumb {
  background: #667eea;
  border-radius: 10px;
}
::-webkit-scrollbar-thumb:hover {
  background: #764ba2;
}
</style>
</head>
<body>
<div class="container">
  <div class="sidebar">
    <h1>My Destiny</h1>
    <button onclick="switchSection('chat')">💬 Chat</button>
    <button onclick="switchSection('book')">📖 Write</button>
    <button onclick="switchSection('memory')">🧠 Memory</button>
    <button onclick="greetCompanion()">👋 Say Hi</button>
  </div>

  <div class="main">
    <div class="header">
      <h2>Your AI Companion</h2>
      <p>⚡ Running locally • Fast & private • Powered by Mistral</p>
    </div>

    <div class="content">
      <div id="chat" class="section active">
        <div class="panel">
          <div class="avatar-section">
            <div class="avatar mood-idle" id="avatar">
              <div class="face">
                <div class="eyes">
                  <div class="eye"><div class="pupil"></div></div>
                  <div class="eye"><div class="pupil"></div></div>
                </div>
                <div class="mouth"></div>
              </div>
            </div>
            <div class="bubble-text" id="bubble">Hey! I'm ready to chat. What's on your mind?</div>
          </div>

          <div class="mood-indicator">
            <div class="mood-dot" id="mood-dot"></div>
            <span class="mood-text" id="mood-text">ready</span>
          </div>
        </div>

        <div class="panel">
          <h3>Start Chatting</h3>
          <div class="chat-container" id="chat-history"></div>
          <div class="input-group">
            <input type="text" id="message-input" placeholder="Type your message..." onkeypress="if(event.key==='Enter')chat()">
            <button onclick="chat()">Send</button>
          </div>
        </div>
      </div>

      <div id="book" class="section">
        <div class="panel">
          <h3>📖 Book Studio</h3>
          <div class="book-controls">
            <select id="book-select" onchange="loadSelectedBook()">
              <option value="">+ New Book</option>
            </select>
            <button onclick="loadBookList()">Refresh</button>
            <button onclick="exportBook()">Export</button>
          </div>
          <input type="text" id="book-title" placeholder="Book title...">
          <textarea id="chapter-input" placeholder="Write your chapter here..."></textarea>
          <div style="display:flex; gap:10px; margin-top:10px;">
            <button onclick="saveBook()">Save Chapter</button>
            <button onclick="generateChapter()">AI Continue</button>
          </div>
          <p class="status-text" id="book-status"></p>
          <h3 style="margin-top:20px;">Previous Chapters</h3>
          <div class="chapters-list" id="chapters-preview">No chapters yet</div>
        </div>
      </div>

      <div id="memory" class="section">
        <div class="panel">
          <h3>🧠 Conversation Memory</h3>
          <p style="font-size:13px; color:#666; margin-bottom:15px;">Your recent exchanges</p>
          <div style="display:flex; gap:10px; margin-bottom:15px;">
            <button onclick="loadMemory()">Load Memory</button>
            <button onclick="clearMemory()" style="background:linear-gradient(135deg,#e74c3c,#c0392b);">Clear</button>
          </div>
          <div class="chapters-list" id="memory-box">No memory yet</div>
        </div>
      </div>
    </div>
  </div>
</div>

<script>
function switchSection(id) {
  document.querySelectorAll('.section').forEach(s => s.classList.remove('active'));
  document.getElementById(id).classList.add('active');
  if (id === 'book') loadBookList();
}

function updateBubble(text) {
  document.getElementById('bubble').innerText = text;
}

function setMood(mood) {
  const avatar = document.getElementById('avatar');
  const moodDot = document.getElementById('mood-dot');
  const moodText = document.getElementById('mood-text');
  
  avatar.className = 'avatar mood-' + mood;
  
  const colors = {
    idle: '#bdc3c7',
    thinking: '#f39c12',
    talking: '#667eea',
    happy: '#27ae60',
    error: '#e74c3c',
    writing: '#3498db'
  };
  moodDot.style.background = colors[mood] || colors.idle;
  moodText.innerText = mood;
}

function greetCompanion() {
  setMood('happy');
  updateBubble('Hello! Ready to help! 😊');
  setTimeout(() => setMood('idle'), 2500);
}

async function chat() {
  const msg = document.getElementById('message-input').value.trim();
  if (!msg) return;
  
  document.getElementById('message-input').value = '';
  setMood('thinking');
  updateBubble('Thinking...');
  
  addMessageToChat('user', msg);
  
  try {
    const response = await fetch('/api/chat/stream', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message: msg })
    });
    
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let fullText = '';
    
    setMood('talking');
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      fullText += decoder.decode(value, { stream: true });
      updateBubble(fullText);
    }
    
    addMessageToChat('ai', fullText);
    setMood('happy');
    setTimeout(() => setMood('idle'), 1500);
  } catch (e) {
    setMood('error');
    updateBubble('Connection error. Is Ollama running?');
  }
}

function addMessageToChat(sender, text) {
  const container = document.getElementById('chat-history');
  const msg = document.createElement('div');
  msg.className = 'message ' + sender;
  msg.innerHTML = '<div class="message-bubble">' + text + '</div>';
  container.appendChild(msg);
  container.scrollTop = container.scrollHeight;
}

async function loadBookList() {
  const res = await fetch('/api/book/list');
  const data = await res.json();
  const select = document.getElementById('book-select');
  select.innerHTML = '<option value="">+ New Book</option>';
  data.books.forEach(b => {
    const opt = document.createElement('option');
    opt.value = b.title;
    opt.textContent = b.title + ' (' + b.chapters + ' chapters)';
    select.appendChild(opt);
  });
}

async function loadSelectedBook() {
  const title = document.getElementById('book-select').value;
  document.getElementById('book-title').value = title;
  document.getElementById('chapter-input').value = '';
  
  if (!title) {
    document.getElementById('book-status').innerText = 'Starting a new book...';
    document.getElementById('chapters-preview').innerText = 'No chapters yet';
    return;
  }
  
  const res = await fetch('/api/book/load?title=' + encodeURIComponent(title));
  const data = await res.json();
  document.getElementById('book-status').innerText = data.chapters.length + ' chapter(s). Ready for chapter ' + (data.chapters.length + 1);
  document.getElementById('chapters-preview').innerText = data.chapters.length
    ? data.chapters.map((c, i) => '--- Chapter ' + c.chapter_number + ' ---\\n' + c.text).join('\\n\\n')
    : 'No chapters yet';
}

async function saveBook() {
  const title = document.getElementById('book-title').value.trim();
  const chapter = document.getElementById('chapter-input').value;
  if (!title || !chapter.trim()) {
    alert('Please add a title and write something!');
    return;
  }
  
  const res = await fetch('/api/book/save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, chapter })
  });
  
  const data = await res.json();
  document.getElementById('book-status').innerText = '✓ ' + data.status;
  document.getElementById('chapter-input').value = '';
  setMood('happy');
  updateBubble('Great! Saved chapter ' + data.chapter_number);
  setTimeout(() => setMood('idle'), 2000);
  loadBookList();
}

async function generateChapter() {
  const title = document.getElementById('book-title').value.trim();
  const chapter = document.getElementById('chapter-input').value;
  setMood('writing');
  updateBubble('Writing your next chapter...');
  
  const res = await fetch('/api/chat/stream', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ message: 'Continue this story chapter:\n\n' + chapter })
  });
  
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let generated = '';
  
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    generated += decoder.decode(value, { stream: true });
    document.getElementById('chapter-input').value = chapter + '\\n\\n' + generated;
  }
  
  setMood('happy');
  updateBubble('Done! Check out your expanded chapter.');
  setTimeout(() => setMood('idle'), 2000);
}

function exportBook() {
  const title = document.getElementById('book-title').value.trim();
  if (!title) { alert('Name your book first!'); return; }
  window.location = '/api/book/export?title=' + encodeURIComponent(title);
}

async function loadMemory() {
  const res = await fetch('/api/memory');
  const data = await res.json();
  document.getElementById('memory-box').innerText = data.memory.length
    ? data.memory.join('\\n---\\n')
    : 'No memory yet. Start chatting!';
}

async function clearMemory() {
  if (!confirm('Clear all conversation history?')) return;
  await fetch('/api/memory/clear', { method: 'POST' });
  document.getElementById('memory-box').innerText = 'Cleared!';
  updateBubble('Memory cleared. Fresh start! 🎉');
}

setMood('idle');
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
    try:
        cur.execute("ALTER TABLE books ADD COLUMN chapter_number INTEGER DEFAULT 1")
    except sqlite3.OperationalError:
        pass
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
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute(
        "SELECT user_message, ai_reply FROM conversations ORDER BY id DESC LIMIT ?",
        (limit,)
    )
    rows = cur.fetchall()
    con.close()
    rows.reverse()
    messages = []
    for user_message, ai_reply in rows:
        messages.append({"role": "user", "content": user_message})
        messages.append({"role": "assistant", "content": ai_reply})
    return messages

def ask_ai_stream(message):
    history = get_recent_history()
    payload = {
        "model": MODEL,
        "stream": True,
        "messages": [
            {"role": "system", "content": "You are a helpful AI assistant. Be brief and conversational."},
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
    except Exception as e:
        yield "Connection error. Make sure Ollama is running."

def ask_ai(message):
    history = get_recent_history()
    payload = {
        "model": MODEL,
        "stream": False,
        "messages": [
            {"role": "system", "content": "You are a helpful AI assistant. Be brief and conversational."},
            *history,
            {"role": "user", "content": message}
        ]
    }
    try:
        r = requests.post(OLLAMA_URL, json=payload, timeout=120)
        r.raise_for_status()
        data = r.json()
        return data.get("message", {}).get("content", "Not sure how to respond.")
    except Exception as e:
        return "Connection error. Is Ollama running?"

def safe_filename(title):
    title = (title or "Untitled").strip() or "Untitled"
    cleaned = re.sub(r"[^A-Za-z0-9_-]+", "_", title)
    return (cleaned.strip("._") or "Untitled")[:100]

@app.route("/")
def home():
    return render_template_string(HTML)

@app.route("/api/chat", methods=["POST"])
def api_chat():
    body = request.get_json(silent=True) or {}
    message = (body.get("message") or "").strip()
    if not message:
        return jsonify({"reply": "Please say something!"}), 400
    reply = ask_ai(message)
    save_chat(message, reply)
    return jsonify({"reply": reply})

@app.route("/api/chat/stream", methods=["POST"])
def api_chat_stream():
    body = request.get_json(silent=True) or {}
    message = (body.get("message") or "").strip()
    if not message:
        return jsonify({"reply": "Please say something!"}), 400
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
    memory = [f"You: {u}\\n\\nMe: {a}" for u, a in rows]
    return jsonify({"memory": memory})

@app.route("/api/memory/clear", methods=["POST"])
def api_memory_clear():
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("DELETE FROM conversations")
    con.commit()
    con.close()
    return jsonify({"status": "Cleared"})

@app.route("/api/book/save", methods=["POST"])
def api_book_save():
    body = request.get_json(silent=True) or {}
    title = (body.get("title") or "Untitled").strip() or "Untitled"
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
    with open(f"books/{safe_filename(title)}.txt", "a", encoding="utf-8") as f:
        f.write(f"\\n\\n--- Chapter {chapter_number} ---\\n{chapter}")
    return jsonify({"status": "Saved", "chapter_number": chapter_number})

@app.route("/api/book/list")
def api_book_list():
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute("""
        SELECT title, COUNT(*) as chapters, MAX(created_at) as updated
        FROM books GROUP BY title ORDER BY updated DESC
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
        return jsonify({"error": "No title"}), 400
    con = sqlite3.connect(DB_PATH)
    cur = con.cursor()
    cur.execute(
        "SELECT chapter, chapter_number FROM books WHERE title = ? ORDER BY chapter_number ASC",
        (title,)
    )
    rows = cur.fetchall()
    con.close()
    if not rows:
        return jsonify({"error": "No chapters"}), 404
    parts = [f"{title}\\n{'=' * len(title)}\\n"]
    for chapter_text, chapter_number in rows:
        parts.append(f"\\n\\n--- Chapter {chapter_number} ---\\n\\n{chapter_text}")
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

if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  echo "Starting Ollama server..."
  nohup ollama serve > ollama.log 2>&1 &
  sleep 3
  if ! curl -s --max-time 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "ERROR: Ollama failed to start. Check ollama.log"
    exit 1
  fi
fi

echo "✓ Ollama ready"
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
