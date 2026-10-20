#!/usr/bin/env python3
"""Stack registry for the Terraform workflows.

The stacks and their apply order come from the `stacks` map in the bootstrap stack's terraform.tfvars, the same map
that creates each stack's CI roles and state prefix (state_prefix = the stack's folder under live/).

  stacks.py list                      all stacks, in apply order (JSON)
  stacks.py affected <base> <head>    stacks affected by the changes between two commits, in apply order (JSON)
  stacks.py affected-files <file>...  same, for a list of changed files
  stacks.py path <stack>              the stack's folder

A stack is affected when a file in its folder changes, or in a module it calls (modules/<name>, referenced by relative
source). Stacks that read an affected stack's SSM outputs (ssm_read_prefixes) are affected too, transitively: they
are re-planned after it applies. Changes to the CI itself (workflows, scripts/ci, .terraform-version) affect every
stack. `affected` also reports "bootstrap": true when the bootstrap stack changed (CI never applies it).
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
BOOTSTRAP = "live/accounts/sandbox/_global/bootstrap"
GLOBAL_TRIGGERS = (".github/workflows/terraform-", "scripts/ci/", ".terraform-version")


def registry():
    """[{name, folder, writes, reads}] in the order of the tfvars `stacks` map."""
    text = open(os.path.join(ROOT, BOOTSTRAP, "terraform.tfvars")).read()
    block = re.search(r"^stacks\s*=\s*\{(.*?)^\}", text, re.S | re.M)
    if not block:
        sys.exit("no stacks map in bootstrap terraform.tfvars")
    entries = re.findall(r"^\s{2}([\w-]+)\s*=\s*\{(.*?)^\s{2}\}", block.group(1), re.S | re.M)
    result = []
    for name, body in entries:
        prefix = re.search(r'state_prefix\s*=\s*"([^"]+)"', body)
        if not prefix:
            sys.exit(f"stack {name} has no state_prefix")
        writes = re.search(r'ssm_write_prefix\s*=\s*"([^"]+)"', body)
        reads = re.search(r"ssm_read_prefixes\s*=\s*\[([^\]]*)\]", body)
        result.append({
            "name": name,
            "folder": f"live/{prefix.group(1)}",
            "writes": writes.group(1) if writes else None,
            "reads": re.findall(r'"([^"]+)"', reads.group(1)) if reads else [],
        })
    if not result:
        sys.exit("stacks map is empty or unparsable")
    return result


def stacks():
    """[(name, folder)] in apply order."""
    return [(s["name"], s["folder"]) for s in registry()]


def modules_of(folder):
    """Module names (modules/<name>) a stack folder calls."""
    names = set()
    for f in os.listdir(os.path.join(ROOT, folder)):
        if f.endswith(".tf"):
            for src in re.findall(r'source\s*=\s*"([^"]+)"', open(os.path.join(ROOT, folder, f)).read()):
                m = re.search(r"(?:^|/)modules/([\w-]+)", src)
                if m:
                    names.add(m.group(1))
    return names


def affected(files):
    files = [f for f in files if f]
    everything = any(f.startswith(GLOBAL_TRIGGERS) for f in files)
    result = []
    for name, folder in stacks():
        hit = everything or any(f.startswith(folder + "/") for f in files)
        if not hit:
            hit = any(f.startswith(f"modules/{m}/") for m in modules_of(folder) for f in files)
        if hit:
            result.append(name)
    # Consumers of affected stacks' outputs, transitively (the registry is in apply order, so one pass suffices).
    reg = registry()
    for s in reg:
        if s["name"] in result:
            continue
        producers = [p for p in reg if p["name"] in result and p["writes"]]
        if any(p["writes"] in s["reads"] for p in producers):
            result.append(s["name"])
    order = [s["name"] for s in reg]
    result.sort(key=order.index)
    bootstrap = any(f.startswith(BOOTSTRAP + "/") for f in files) or any(
        f.startswith(f"modules/{m}/") for m in modules_of(BOOTSTRAP) for f in files)
    return {"stacks": result, "bootstrap": bootstrap}


def changed_files(base, head):
    out = subprocess.run(["git", "-C", ROOT, "diff", "--name-only", f"{base}...{head}"],
                         check=True, capture_output=True, text=True).stdout
    return out.splitlines()


def main(argv):
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd == "list":
        print(json.dumps([n for n, _ in stacks()]))
    elif cmd == "affected" and len(argv) == 4:
        print(json.dumps(affected(changed_files(argv[2], argv[3]))))
    elif cmd == "affected-files":
        print(json.dumps(affected(argv[2:])))
    elif cmd == "path" and len(argv) == 3:
        paths = dict(stacks())
        if argv[2] not in paths:
            sys.exit(f"unknown stack {argv[2]}")
        print(paths[argv[2]])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
