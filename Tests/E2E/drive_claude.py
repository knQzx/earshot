#!/usr/bin/env python3
import argparse, fcntl, json, os, pty, re, select, struct, sys, tempfile, termios, time

ap = argparse.ArgumentParser()
ap.add_argument("--hook", required=True)
ap.add_argument("--prompt", default="Use the Bash tool to run exactly: mkdir -p e2e_dir && echo hi > e2e_dir/a.txt")
ap.add_argument("--keys", default="", help="comma list of seconds:key after prompt, key in enter|esc|none")
ap.add_argument("--wait", type=float, default=40)
ap.add_argument("--workdir", default=None)
ap.add_argument("--permission-mode", default="manual")
ap.add_argument("--extra-settings", default=None, help="JSON object merged into the generated settings")
ap.add_argument("--env", action="append", default=[], help="KEY=VALUE for the claude process and its hooks")
ap.add_argument("--isolated", action="store_true", help="skip user settings and MCP servers")
a = ap.parse_args()

work = a.workdir or tempfile.mkdtemp(prefix="earshot-e2e-")
events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
          "PermissionRequest", "PermissionDenied", "Notification", "Stop", "StopFailure"]
hook = {"type": "command", "command": json.dumps(a.hook)}
settings = {"hooks": {e: [{"matcher": "*", "hooks": [dict(hook, timeout=86400 if e in ("PermissionRequest", "PreToolUse") else 10)]}] for e in events}}
if a.extra_settings:
    for k, v in json.loads(a.extra_settings).items():
        if isinstance(v, dict) and isinstance(settings.get(k), dict):
            settings[k].update(v)
        else:
            settings[k] = v
sp = os.path.join(work, ".e2e-settings.json")
json.dump(settings, open(sp, "w"))

pid, fd = pty.fork()
if pid == 0:
    os.chdir(work)
    os.environ["CLAUDE_CODE_FORCE_SESSION_PERSISTENCE"] = "1"
    for kv in a.env:
        k, _, v = kv.partition("=")
        os.environ[k] = v
    extra = ["--setting-sources", "project,local", "--strict-mcp-config"] if a.isolated else []
    os.execvp("claude", ["claude", "--settings", sp, "--permission-mode", a.permission_mode, "--model", "haiku"] + extra)

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
screen = bytearray()

def pump(sec):
    end = time.time() + sec
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                screen.extend(os.read(fd, 65536))
            except OSError:
                return

def text():
    t = screen.decode("utf-8", "replace")
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07|\x1b.", "", t).replace(" ", "")

pump(6)
if "trustthisfolder" in text():
    os.write(fd, b"\x1b[B"); pump(0.5); os.write(fd, b"\r"); pump(5)
for ch in a.prompt:
    os.write(fd, ch.encode()); time.sleep(0.008)
pump(1); os.write(fd, b"\r")
t0 = time.time()
plan = []
for item in filter(None, a.keys.split(",")):
    s, k = item.split(":")
    plan.append((float(s), k))
for s, k in sorted(plan):
    pump(max(0, t0 + s - time.time()))
    print(f"[drive] t+{time.time()-t0:.1f}s key {k}", flush=True)
    if k == "enter": os.write(fd, b"\r")
    elif k == "esc": os.write(fd, b"\x1b")
pump(max(0, t0 + a.wait - time.time()))
os.write(fd, b"\x03"); pump(0.5); os.write(fd, b"\x03"); pump(2)
try:
    os.kill(pid, 9)
except ProcessLookupError:
    pass
print(f"[drive] workdir {work}")
print(f"[drive] created={os.path.exists(os.path.join(work, 'e2e_dir', 'a.txt'))}")
open(os.path.join(work, ".screen.txt"), "w").write(text())
