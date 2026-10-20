#!/usr/bin/python3 -Bsu
"""Drive the repro guest over its VBox serial console (TCP).

  serialctl.py --port P login   [--login-timeout N]
  serialctl.py --port P ping     [--timeout N] [--login-timeout N]
  serialctl.py --port P run "cmd"[--timeout N] [--login-timeout N]
  serialctl.py --port P bg  "cmd"
  serialctl.py --port P logcat   --timeout N      # stream serial for N s

Exit: 0 ok, 124 timeout/frozen, 2 no-shell.
"""
import sys, os, time, argparse, re
import pexpect

PROMPT = r"RPMARK> "
SETPS1 = "export PROMPT_COMMAND=; export PS1='RP''MARK> '"
BPOFF  = "bind 'set enable-bracketed-paste off' 2>/dev/null; true"
# Serial-console login password. MUST match the password set in
# cloud-init/user-data (same placeholder by default); override via env when you
# provision the guest with a different one.
PW = os.environ.get("REPRO_SERIAL_PW", "CHANGEME-throwaway")
ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")

def clean(s): return ANSI.sub("", s or "").replace("\r", "")

def connect(port, timeout=15):
    return pexpect.spawn("socat -,raw,echo=0 TCP:127.0.0.1:%d" % port,
                         encoding="utf-8", codec_errors="ignore", timeout=timeout)

def ensure_login(child, timeout):
    end = time.time() + timeout
    child.send("\r")
    while time.time() < end:
        i = child.expect([r"login:\s*", r"[Pp]assword:\s*", PROMPT,
                          pexpect.TIMEOUT, pexpect.EOF], timeout=4)
        if i == 0:   child.send("root\r")
        elif i == 1: child.send(PW + "\r")
        elif i == 2: return True
        elif i == 3: child.send("\r" + BPOFF + "\r" + SETPS1 + "\r")
        else:        return False
    return False

def run(child, cmd, timeout):
    child.send(cmd + "\r")
    try:
        child.expect(PROMPT, timeout=timeout)
    except (pexpect.TIMEOUT, pexpect.EOF):
        return None
    return clean(child.before)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--login-timeout", type=int, default=45)
    ap.add_argument("action", choices=["login","run","bg","ping","logcat"])
    ap.add_argument("cmd", nargs="?", default="")
    a = ap.parse_args()

    if a.action == "logcat":
        child = connect(a.port, timeout=a.timeout + 5)
        end = time.time() + a.timeout
        buf = []
        while time.time() < end:
            try:
                buf.append(child.read_nonblocking(4096, timeout=2))
            except pexpect.TIMEOUT:
                pass
            except pexpect.EOF:
                break
        sys.stdout.write(clean("".join(buf)))
        sys.exit(0)

    child = connect(a.port)
    if not ensure_login(child, a.login_timeout):
        print("NO-SHELL", file=sys.stderr); sys.exit(124)
    child.send(BPOFF + "\r")
    try: child.expect(PROMPT, timeout=8)
    except Exception: pass
    child.send(SETPS1 + "\r")
    try: child.expect(PROMPT, timeout=8)
    except Exception: pass
    child.send("\r")
    try: child.expect(PROMPT, timeout=8)
    except Exception: pass

    if a.action == "login":
        print("LOGIN-OK"); sys.exit(0)
    if a.action == "ping":
        out = run(child, "echo PONG; uptime|tr -s ' '", a.timeout)
        if out is None: print("FROZEN"); sys.exit(124)
        print(clean(out).strip()); sys.exit(0)
    if a.action == "bg":
        q = "'" + a.cmd.replace("'", "'\\''") + "'"
        out = run(child, "nohup bash -c %s >/tmp/bg.log 2>&1 & disown; echo BG=$!" % q, 15)
        print((out or "").strip()); sys.exit(0)
    if a.action == "run":
        out = run(child, a.cmd, a.timeout)
        if out is None: print("FROZEN", file=sys.stderr); sys.exit(124)
        sys.stdout.write(out); sys.exit(0)

if __name__ == "__main__":
    main()
