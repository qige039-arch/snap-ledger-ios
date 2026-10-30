import json, subprocess, sys, time, urllib.request, urllib.error

out = subprocess.run([r"C:\Program Files\Git\mingw64\bin\git-credential-manager.exe", "get"],
                     input="protocol=https\nhost=github.com\n\n",
                     capture_output=True, text=True, encoding="utf-8")
tok = [l[9:] for l in out.stdout.splitlines() if l.startswith("password=")][0]
BASE = "https://api.github.com/repos/qige039-arch/snap-ledger-ios"


def get(u):
    r = urllib.request.Request(u, headers={
        "Authorization": f"Bearer {tok}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "x"})
    return json.loads(urllib.request.urlopen(r, timeout=40).read())


run_id = sys.argv[1]
deadline = time.time() + 900
last = None
while time.time() < deadline:
    try:
        w = get(f"{BASE}/actions/runs/{run_id}")
    except urllib.error.URLError as e:
        print("net", e, flush=True)
        time.sleep(8)
        continue
    st, cc = w["status"], w["conclusion"]
    if (st, cc) != last:
        print(f"{st} / {cc}", flush=True)
        last = (st, cc)
    if st == "completed":
        jobs = get(f"{BASE}/actions/runs/{run_id}/jobs")["jobs"]
        for j in jobs:
            print(f"  job {j['name']}: {j['conclusion']}")
            for s in j["steps"]:
                print(f"    - {s['name']}: {s['conclusion']}")
        sys.exit(0)
    time.sleep(12)
print("timeout")
sys.exit(1)
