"""Secret scan behind tools/check-secrets.sh (the pre-commit hook)."""
import subprocess, sys

mode = sys.argv[1]
NOT_SECRET = {"LM_HOST", "LM_USER"}
values = {}
for line in open(".env", encoding="utf-8"):
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        v = v.strip().strip("'\"")
        if k.strip() not in NOT_SECRET and len(v) >= 4:
            values[k.strip()] = v

def git(*args):
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout

if mode == "all":
    files = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    blobs = {f.decode(): open(f, "rb").read() for f in files if f}
else:
    files = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z").split(b"\0")
    blobs = {f.decode(): git("show", ":" + f.decode()) for f in files if f}

bad = [(path, name) for path, data in blobs.items()
       for name, value in values.items() if value.encode() in data]
if any(p == ".env" for p in blobs):
    bad.append((".env", "the whole file"))
for path, name in bad:
    print(f"check-secrets: {path} contains the value of {name}", file=sys.stderr)
if bad:
    sys.exit("check-secrets: commit refused; use ${NAME} placeholders (see tools/README.md)")
print(f"check-secrets: {len(blobs)} file(s) clean")
