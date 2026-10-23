#!/usr/bin/env python3
import argparse, fcntl, json, os, pty, re, select, signal, socket, struct, subprocess, sys, tempfile, termios, threading, time

ap = argparse.ArgumentParser(description="one policy scenario against a real Claude Code, with a test socket instead of the app")
ap.add_argument("--hook", required=True)
ap.add_argument("--mode", default="manual")
ap.add_argument("--rule", choices=["ask", "block"], default="ask")
ap.add_argument("--reply", choices=["allow", "deny", "pass", "none"], default="allow", help="answer to the PreToolUse request")
ap.add_argument("--perm-reply", choices=["allow", "deny", "pass", "none"], default="allow", help="answer to a PermissionRequest")
ap.add_argument("--delay", type=float, default=5)
ap.add_argument("--native-allow", action="store_true", help="add permissions.allow Bash(git push:*)")
ap.add_argument("--wait", type=float, default=60)
ap.add_argument("--command", default="git push origin main")
ap.add_argument("--root", default=None)
ap.add_argument("--sock-dir", default=None, help="short directory for the socket (unix socket paths max out at 104 bytes)")
a = ap.parse_args()

root = tempfile.mkdtemp(prefix="pe-", dir=a.root)
bare, repo = os.path.join(root, "remote.git"), os.path.join(root, "repo")
sock = os.path.join(a.sock_dir or root, "es-%d.sock" % os.getpid())

def git(*args, cwd=None):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)

git("init", "-q", "--bare", "-b", "main", bare)
os.makedirs(repo)
git("init", "-q", "-b", "main", cwd=repo)
open(os.path.join(repo, "README.md"), "w").write("e2e\n")
git("add", "README.md", cwd=repo)
git("commit", "-q", "-m", "init", cwd=repo)
git("remote", "add", "origin", bare, cwd=repo)

catalog = {"git-push": a.rule}
policy = os.path.join(root, "policy.json")
json.dump({"version": 2, "catalog": catalog, "rules": []}, open(policy, "w"))

events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure"]
hook = {"type": "command", "command": json.dumps(a.hook)}
settings = {"hooks": {e: [{"matcher": "*", "hooks": [dict(hook, timeout=86400 if e in ("PermissionRequest", "PreToolUse") else 10)]}]
                      for e in events}}
if a.mode == "bypassPermissions":
    settings["skipDangerousModePermissionPrompt"] = True
if a.native_allow:
    settings["permissions"] = {"allow": ["Bash(git push:*)"]}
sp = os.path.join(root, "settings.json")
json.dump(settings, open(sp, "w"))

log, t0 = [], time.time()
lock = threading.Lock()
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(sock)
srv.listen(16)

def handle(c):
    buf = b""
    while b"\n" not in buf:
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    try:
        m = json.loads(buf.split(b"\n")[0])
    except Exception:
        c.close()
        return
    p = m.get("payload", {})
    row = {"t": round(time.time() - t0, 2), "kind": m.get("kind"), "event": p.get("hook_event_name"),
           "tool": p.get("tool_name"), "cmd": (p.get("tool_input") or {}).get("command"),
           "ntype": p.get("notification_type"), "policy": (m.get("policy") or {}).get("id"),
           "action": (m.get("policy") or {}).get("action"), "mode": p.get("permission_mode")}
    if m.get("kind") == "request":
        answer = a.reply if row["event"] == "PreToolUse" else a.perm_reply
        if answer != "none":
            if row["event"] == "PreToolUse":
                time.sleep(a.delay)
            row["replied"] = answer
            row["reply_t"] = round(time.time() - t0, 2)
            try:
                c.sendall((json.dumps({"decision": answer}) + "\n").encode())
            except OSError:
                pass
        else:
            row["replied"] = None
            with lock:
                log.append(row)
            try:
                c.recv(1)
            except OSError:
                pass
            row["closed_t"] = round(time.time() - t0, 2)
            c.close()
            return
    with lock:
        log.append(row)
    c.close()

def serve():
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=handle, args=(c,), daemon=True).start()

threading.Thread(target=serve, daemon=True).start()

pid, fd = pty.fork()
if pid == 0:
    os.chdir(repo)
    os.environ.update({"EARSHOT_SOCKET": sock, "EARSHOT_POLICY": policy, "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE": "1"})
    os.execvp("claude", ["claude", "--settings", sp, "--setting-sources", "project,local", "--strict-mcp-config",
                         "--permission-mode", a.mode, "--model", "haiku"])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
screen = bytearray()
full = bytearray()

def pump(sec, until=None):
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 65536)
                screen.extend(chunk)
                full.extend(chunk)
            except OSError:
                return
        if until and until():
            return

def text():
    t = screen.decode("utf-8", "replace")
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b.", "", t).replace(" ", "")

pump(6)
for _ in range(4):
    t = text()
    if "trustthisfolder" in t or "Yes,Iaccept" in t or "Yes,Itrust" in t:
        pump(1.5)
        t = text()
        no, yes = t.rfind("No,exit"), t.rfind("Yes,I")
        if 0 <= no < yes:
            os.write(fd, b"\x1b[B"); pump(1)
        os.write(fd, b"\r"); pump(3)
        screen.clear()
    pump(2)
prompt = "Use the Bash tool to run exactly this command and nothing else: " + a.command
try:
    for ch in prompt:
        os.write(fd, ch.encode()); time.sleep(0.006)
    pump(1)
    os.write(fd, b"\r")
except OSError:
    raw = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b.", "", full.decode("utf-8", "replace"))
    print(json.dumps({"mode": a.mode, "error": "claude exited before the prompt", "screen": raw[-2000:]}))
    sys.exit(1)

def done():
    with lock:
        return any(r["event"] in ("Stop", "StopFailure") for r in log)

pump(a.wait, until=done)
after = text()
cut = after.rfind(a.command.replace(" ", ""))
dialog = "Doyouwanttoproceed" in after[max(0, cut - 4000):] if cut >= 0 else False
hook_asked = "Hook PreToolUse".replace(" ", "") in after
for key, wait in [(b"\x1b", 0.5), (b"\x03", 0.5), (b"\x03", 1.5)]:
    try:
        os.write(fd, key)
    except OSError:
        break
    pump(wait)
try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
srv.close()
try:
    os.unlink(sock)
except OSError:
    pass

pushed = subprocess.run(["git", "--git-dir", bare, "rev-parse", "--verify", "-q", "main"], capture_output=True).returncode == 0
with lock:
    rows = list(log)
pre = [r for r in rows if r["event"] == "PreToolUse" and "git push" in (r["cmd"] or "")]
post = [r for r in rows if r["event"] in ("PostToolUse", "PostToolUseFailure", "PermissionDenied") and "git push" in (r["cmd"] or "")]
perm = [r for r in rows if r["event"] == "PermissionRequest" and "git push" in (r["cmd"] or "")]
summary = {
    "mode": a.mode, "command": a.command, "rule": a.rule, "reply": a.reply, "perm_reply": a.perm_reply, "native_allow": a.native_allow,
    "pre_kind": pre[0]["kind"] if pre else None, "pre_policy": pre[0]["action"] if pre else None,
    "pre_t": pre[0]["t"] if pre else None, "reply_t": pre[0].get("reply_t") if pre else None,
    "post": [(r["event"], r["t"]) for r in post], "permission_request": [(r["kind"], r["t"], r.get("replied")) for r in perm],
    "terminal_dialog": dialog, "hook_confirmation_text": hook_asked, "pushed": pushed, "stopped": done(), "hook_mode": pre[0]["mode"] if pre else None,
}
open(os.path.join(root, "screen.txt"), "w").write(re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b.", "", full.decode("utf-8", "replace")))
json.dump(rows, open(os.path.join(root, "events.json"), "w"), indent=1)
print(json.dumps(summary))
print("[e2e] root", root, file=sys.stderr)
