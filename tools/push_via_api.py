"""
git push 的兜底通道。

背景：这台机器到 github.com:443（git 传输端口）时通时不通，但 api.github.com 一直可用。
所以当 `git push` 报 "Connection was reset" / "Could not connect to server" 时，
用 Git Data API 直接把改动提交上去，效果等价于一次普通提交，也会触发 CI。

用法：
    python tools/push_via_api.py            # 自动找出相对 origin/main 的所有改动
    python tools/push_via_api.py -m "说明"  # 自定义 commit message
    python tools/push_via_api.py 文件1 文件2 # 只提交指定文件

注意：
- 只处理新增/修改，不处理删除（仓库里几乎不会有删文件的需求，真有就用网页删）。
- 走完这条路后，本地与远端会分叉。等 github.com 能连上时执行一次
  `git fetch origin && git reset --hard origin/main` 把本地对齐，别直接 push。
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "qige039-arch/snap-ledger-ios"
API = f"https://api.github.com/repos/{REPO}"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GIT = "git"


def get_token():
    out = subprocess.run(
        [r"C:\Program Files\Git\mingw64\bin\git-credential-manager.exe", "get"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, encoding="utf-8",
    )
    for line in out.stdout.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("取不到 GitHub token（Git Credential Manager 里没有 github.com 凭据）")


TOKEN = get_token()


def req(method, url, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": "snap-ledger-build",
    })
    try:
        with urllib.request.urlopen(r, timeout=40) as resp:
            return json.loads(resp.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode()[:500])
        raise


def git(*args):
    return subprocess.run([GIT, "-C", ROOT] + list(args),
                          capture_output=True, text=True, encoding="utf-8")


def changed_files():
    """已提交未推送的 + 工作区未提交/未跟踪的"""
    seen, files = set(), []
    out = git("diff", "--name-only", "origin/main", "HEAD")
    for p in out.stdout.splitlines():
        p = p.strip()
        if p and p not in seen:
            seen.add(p); files.append(p)
    out = git("status", "--porcelain", "-uall")
    for line in out.stdout.splitlines():
        if len(line) < 4:
            continue
        p = line[3:].strip().strip('"')
        if p and p not in seen:
            seen.add(p); files.append(p)
    return files


def main():
    args = sys.argv[1:]
    msg = "同步改动"
    if "-m" in args:
        i = args.index("-m")
        msg = args[i + 1]
        del args[i:i + 2]
    files = args or changed_files()
    if not files:
        raise SystemExit("没有需要提交的改动")

    head = req("GET", f"{API}/git/ref/heads/main")
    head_sha = head["object"]["sha"]
    base_tree = req("GET", f"{API}/git/commits/{head_sha}")["tree"]["sha"]
    print("远端 head:", head_sha[:10])

    entries = []
    for rel in files:
        full = os.path.join(ROOT, rel)
        if not os.path.exists(full):
            print(f"  跳过（本地不存在，可能是删除）: {rel}")
            continue
        with open(full, "rb") as f:
            raw = f.read()
        blob = req("POST", f"{API}/git/blobs", {
            "content": base64.b64encode(raw).decode(),
            "encoding": "base64",
        })
        entries.append({"path": rel, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        print(f"  + {rel}  {len(raw)} bytes")

    if not entries:
        raise SystemExit("没有可提交的文件")

    tree = req("POST", f"{API}/git/trees", {"base_tree": base_tree, "tree": entries})
    commit = req("POST", f"{API}/git/commits", {
        "message": msg, "tree": tree["sha"], "parents": [head_sha],
    })
    req("PATCH", f"{API}/git/refs/heads/main", {"sha": commit["sha"], "force": False})
    print("新 commit:", commit["sha"][:10])

    req("POST", f"{API}/actions/workflows/ios.yml/dispatches", {"ref": "main"})
    print("已触发 workflow")


if __name__ == "__main__":
    main()
