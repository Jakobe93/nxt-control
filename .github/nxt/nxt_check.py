#!/usr/bin/env python3
"""nxt_check - shared checks for nxt- FiveM resources.

    nxt_check.py lua                  syntax-check every tracked .lua file
    nxt_check.py contracts            write contracts.json for this resource
    nxt_check.py contracts --check    fail if contracts.json is out of date
    nxt_check.py docs [--base REF]    check that docs follow the change (pull requests)
    nxt_check.py required             fail if a file every resource repo must have is missing
    nxt_check.py eol [--base REF]     fail if a changed file's line endings were converted (--fix puts them back)

Python 3 standard library only. The Lua check also needs a stock Lua 5.4
interpreter on PATH (lua5.4 or lua), or one named by the NXT_LUA variable.

The canonical copy lives in Jakobe93/nxt-md under tools/. Resources carry a
vendored copy in .github/nxt/ - change it in nxt-md and re-sync, never in a
resource repo.
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

SKIP_DIRS = ("node_modules/", "web/", "web-src/", "html/", "docs/", "tests/",
             "test/", "install/", "setup/", "tools/", ".github/", "dist/")


# --------------------------------------------------------------------------
# file listing
# --------------------------------------------------------------------------
def tracked(root, suffix):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "*" + suffix],
                             capture_output=True, text=True, check=True).stdout
        files = [f for f in out.splitlines() if f]
    except Exception:
        files = []
        for dp, dn, fn in os.walk(root):
            dn[:] = [d for d in dn if d not in (".git", "node_modules")]
            for f in fn:
                if f.endswith(suffix):
                    files.append(os.path.relpath(os.path.join(dp, f), root))
    return sorted(f.replace("\\", "/") for f in files)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# --------------------------------------------------------------------------
# Lua scanning: split a file into code / string / comment regions
# --------------------------------------------------------------------------
def _long_bracket(src, i):
    """If src[i] opens a long bracket ([[ or [==[), return its level, else -1."""
    if src[i] != "[":
        return -1
    j = i + 1
    while j < len(src) and src[j] == "=":
        j += 1
    if j < len(src) and src[j] == "[":
        return j - i - 1
    return -1


def scan(src):
    """Yield (kind, text) with kind in code | str | comment | hash."""
    i, n, start = 0, len(src), 0
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if c == "-" and nxt == "-":
            if start < i:
                yield "code", src[start:i]
            lvl = _long_bracket(src, i + 2) if i + 2 < n else -1
            if lvl >= 0:
                close = "]" + "=" * lvl + "]"
                end = src.find(close, i + 2)
                end = n if end < 0 else end + len(close)
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end
            yield "comment", src[i:end]
            i = start = end
        elif c == "/" and nxt == "*":            # Cfx C-style block comment
            if start < i:
                yield "code", src[start:i]
            end = src.find("*/", i + 2)
            end = n if end < 0 else end + 2
            yield "comment", src[i:end]
            i = start = end
        elif c in "\"'":
            if start < i:
                yield "code", src[start:i]
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            end = min(j + 1, n)
            yield "str", src[i:end]
            i = start = end
        elif c == "`":                           # Cfx compile-time hash
            if start < i:
                yield "code", src[start:i]
            end = src.find("`", i + 1)
            end = n if end < 0 else end + 1
            yield "hash", src[i:end]
            i = start = end
        elif c == "[" and _long_bracket(src, i) >= 0:
            if start < i:
                yield "code", src[start:i]
            lvl = _long_bracket(src, i)
            close = "]" + "=" * lvl + "]"
            end = src.find(close, i + 2)
            end = n if end < 0 else end + len(close)
            yield "str", src[i:end]
            i = start = end
        else:
            i += 1
    if start < n:
        yield "code", src[start:]


_COMPOUND = re.compile(r"(\.\.|<<|>>|//|[-+*/%^&|])=(?!=)")
_SAFE_NAV = re.compile(r"\?(?=[.\[:])")


def to_stock_lua(src):
    """Rewrite Cfx Lua extensions so stock Lua 5.4 can parse the file.

    Line numbers are preserved. The result is only good for a syntax check."""
    out = []
    for kind, text in scan(src):
        if kind == "code":
            text = text.replace("!=", "~=")
            text = _SAFE_NAV.sub("", text)
            text = _COMPOUND.sub("=", text)
        elif kind == "hash":
            text = "0" + "\n" * text.count("\n")
        elif kind == "comment" and text.startswith("/*"):
            text = " " + "\n" * text.count("\n")
        out.append(text)
    return "".join(out)


def code_only(src):
    """Source with comments blanked out; strings are kept."""
    return "".join(" " if k == "comment" else t for k, t in scan(src))


# --------------------------------------------------------------------------
# lua syntax check
# --------------------------------------------------------------------------
LUA_DRIVER = r"""
local bad = 0
for line in io.lines(arg[1]) do
  local orig, tmp = line:match('^(.-)\t(.*)$')
  local fh = assert(io.open(tmp, 'rb')); local src = fh:read('a'); fh:close()
  local ok, err = load(src, '@' .. orig, 't')
  if not ok then
    -- data fragments (item / config snippets) are table bodies, not chunks
    local ok2 = load('return {' .. src .. '\n}', '@' .. orig, 't')
    if not ok2 then
      bad = bad + 1
      local ln, msg = err:match(':(%d+): (.*)$')
      print(string.format('::error file=%s,line=%s::%s', orig, ln or 1, msg or err))
      print(err)
    end
  end
end
os.exit(bad == 0 and 0 or 1)
"""


def find_lua():
    for name in (os.environ.get("NXT_LUA"), "lua5.4", "lua"):
        if not name:
            continue
        path = shutil.which(name) or (name if os.path.isfile(name) else None)
        if not path:
            continue
        ver = subprocess.run([path, "-v"], capture_output=True, text=True)
        if "5.4" in (ver.stdout + ver.stderr):
            return path
    sys.exit("nxt_check: no Lua 5.4 interpreter found (install lua5.4 or set NXT_LUA)")


def cmd_lua(root):
    lua = find_lua()
    files = tracked(root, ".lua")
    with tempfile.TemporaryDirectory() as tmp:
        rows = []
        for idx, rel in enumerate(files):
            dst = os.path.join(tmp, "%d.lua" % idx)
            with open(dst, "w", encoding="utf-8") as fh:
                fh.write(to_stock_lua(read(os.path.join(root, rel))))
            rows.append(rel + "\t" + dst)
        listing = os.path.join(tmp, "files.txt")
        driver = os.path.join(tmp, "driver.lua")
        with open(listing, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rows) + ("\n" if rows else ""))
        with open(driver, "w", encoding="utf-8") as fh:
            fh.write(LUA_DRIVER)
        rc = subprocess.run([lua, driver, listing]).returncode
    print("lua: %d files checked, %s" % (len(files), "all parse" if rc == 0 else "syntax errors found"))
    return rc


# --------------------------------------------------------------------------
# contracts
# --------------------------------------------------------------------------
_Q = r"""['"]([^'"\n]+)['"]"""
RE_EXPORT_DEF = re.compile(r"""(?<![\w.:\]])exports\(\s*""" + _Q)
# exports registered in a loop or through the __cfx_export_ event: names unknown statically
RE_EXPORT_DYN = re.compile(r"""(?<![\w.:\]])exports\(\s*[A-Za-z_]|__cfx_export_""")
RE_NET_EVENT = re.compile(r"""\bRegisterNetEvent\(\s*""" + _Q)
RE_CB_DEF = re.compile(r"""\blib\.callback\.register\(\s*""" + _Q)
RE_EXPORT_USE = re.compile(
    r"""\bexports(?:\[\s*['"]([^'"\n]+)['"]\s*\]|\.([A-Za-z_]\w*))\s*[:.]\s*([A-Za-z_]\w*)""")
RE_EVENT_USE = re.compile(
    r"""\b(TriggerEvent|TriggerServerEvent|TriggerClientEvent|TriggerLatentServerEvent|TriggerLatentClientEvent)\(\s*""" + _Q)
RE_CB_USE = re.compile(r"""\blib\.callback(?:\.await)?\(\s*""" + _Q)

RE_MANIFEST_BLOCK = re.compile(r"""^\s*([a-z_]+)\s*(?:\(\s*)?\{(.*?)\}""", re.S | re.M)
RE_MANIFEST_ONE = re.compile(r"""^\s*([a-z_]+)\s*\(?\s*['"]([^'"\n]+)['"]""", re.M)


def parse_manifest(root):
    path = os.path.join(root, "fxmanifest.lua")
    # resource name: fxmanifest `name`, else the name pinned in contracts.json,
    # else the folder name (a repo may be named differently from its resource)
    pinned = None
    try:
        pinned = json.loads(read(os.path.join(root, "contracts.json"))).get("resource")
    except Exception:
        pass
    info = {"name": pinned or os.path.basename(os.path.abspath(root)), "version": None,
            "provides": [], "dependencies": [],
            "client": [], "server": [], "shared": [],
            "exports_client": [], "exports_server": []}
    if not os.path.isfile(path):
        return info
    src = code_only(read(path))
    keymap = {"client_scripts": "client", "client_script": "client",
              "server_scripts": "server", "server_script": "server",
              "shared_scripts": "shared", "shared_script": "shared",
              "dependencies": "dependencies", "dependency": "dependencies",
              "provide": "provides",
              "exports": "exports_client", "export": "exports_client",
              "server_exports": "exports_server", "server_export": "exports_server"}
    for key, body in RE_MANIFEST_BLOCK.findall(src):
        if key in keymap:
            info[keymap[key]] += re.findall(_Q, body)
    for key, val in RE_MANIFEST_ONE.findall(src):
        if key == "version":
            info["version"] = val
        elif key == "name":
            info["name"] = val
        elif key in keymap:
            info[keymap[key]].append(val)
    for key in ("provides", "dependencies"):
        info[key] = sorted(set(info[key]))
    return info


def glob_match(rel, pattern):
    if pattern.startswith("@"):
        return False
    regex = re.escape(pattern).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.fullmatch(regex, rel) is not None


def side_of(rel, info):
    hits = [s for s in ("client", "server", "shared") if any(glob_match(rel, p) for p in info[s])]
    if "shared" in hits or ("client" in hits and "server" in hits):
        return "shared"
    if hits:
        return hits[0]
    low = "/" + rel.lower()
    if "/client" in low or "/cl_" in low:
        return "client"
    if "/server" in low or "/sv_" in low:
        return "server"
    return "shared"


def build_contracts(root):
    info = parse_manifest(root)
    names = {info["name"], *info["provides"]}
    provides = {"exports": {"client": set(info["exports_client"]),
                            "server": set(info["exports_server"])},
                "events": set(), "callbacks": set()}
    uses = {"exports": {}, "events": set(), "callbacks": set()}
    dynamic = False
    for rel in tracked(root, ".lua"):
        if rel == "fxmanifest.lua" or rel.startswith(SKIP_DIRS):
            continue
        src = code_only(read(os.path.join(root, rel)))
        side = side_of(rel, info)
        for name in RE_EXPORT_DEF.findall(src):
            for s in (("client", "server") if side == "shared" else (side,)):
                provides["exports"][s].add(name)
        dynamic = dynamic or bool(RE_EXPORT_DYN.search(src))
        provides["events"].update(RE_NET_EVENT.findall(src))
        provides["callbacks"].update(RE_CB_DEF.findall(src))
        for a, b, fn in RE_EXPORT_USE.findall(src):
            res = a or b
            if res not in names:
                uses["exports"].setdefault(res, set()).add(fn)
        uses["events"].update(name for _, name in RE_EVENT_USE.findall(src))
        uses["callbacks"].update(RE_CB_USE.findall(src))
    # only what crosses the resource boundary is a contract
    uses["events"] -= provides["events"]
    uses["callbacks"] -= provides["callbacks"]
    own = tuple(n + ":" for n in names)
    uses["events"] = {e for e in uses["events"] if ":" in e and not e.startswith(own)}
    uses["callbacks"] = {c for c in uses["callbacks"] if ":" in c and not c.startswith(own)}
    return {
        "resource": info["name"],
        "version": info["version"],
        "aliases": info["provides"],
        "dependencies": info["dependencies"],
        "provides": {
            "exports": {"client": sorted(provides["exports"]["client"]),
                        "server": sorted(provides["exports"]["server"])},
            # true when some exports are registered at run time and cannot be listed
            "dynamic_exports": dynamic,
            "events": sorted(provides["events"]),
            "callbacks": sorted(provides["callbacks"]),
        },
        "uses": {
            "exports": {k: sorted(v) for k, v in sorted(uses["exports"].items())},
            "events": sorted(uses["events"]),
            "callbacks": sorted(uses["callbacks"]),
        },
    }


def flat_provides(data):
    p = data.get("provides", {})
    out = set()
    for side in ("client", "server"):
        out |= {"export %s (%s)" % (n, side) for n in p.get("exports", {}).get(side, [])}
    out |= {"event " + n for n in p.get("events", [])}
    out |= {"callback " + n for n in p.get("callbacks", [])}
    return out


def dump(data):
    return json.dumps(data, indent=2, sort_keys=False) + "\n"


def cmd_contracts(root, check):
    path = os.path.join(root, "contracts.json")
    new = build_contracts(root)
    old = json.loads(read(path)) if os.path.isfile(path) else None
    if not check:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(dump(new))
        print("contracts: wrote contracts.json (%d provided, %d resources used)"
              % (len(flat_provides(new)), len(new["uses"]["exports"])))
        return 0
    if old is None:
        print("::error file=contracts.json::contracts.json is missing - run "
              "`python3 .github/nxt/nxt_check.py contracts` and commit it")
        return 1
    # the version line is informational; a bump alone is not a contract change
    same = {k: v for k, v in old.items() if k != "version"} == {k: v for k, v in new.items() if k != "version"}
    removed = sorted(flat_provides(old) - flat_provides(new))
    added = sorted(flat_provides(new) - flat_provides(old))
    for item in removed:
        print("::warning file=contracts.json::REMOVED %s - other resources may call it; "
              "check CONTRACTS.md in nxt-md and open an issue on each dependant" % item)
    for item in added:
        print("::notice file=contracts.json::added %s" % item)
    if same:
        print("contracts: contracts.json is up to date")
        return 0
    print("::error file=contracts.json::contracts.json is out of date (%d added, %d removed) - run "
          "`python3 .github/nxt/nxt_check.py contracts` and commit the result"
          % (len(added), len(removed)))
    return 1


# --------------------------------------------------------------------------
# docs: do the README, reference docs and README images follow the change?
#
# WORKING.md rule 16. Docs are updated for a major design change, a change to
# exports / events / callbacks, or a new feature. A bug fix or quick tweak
# needs none, unless it changes how the UI looks, and then the images are
# re-rendered. Only the contract case can be told apart by a script, so only
# that one fails; the other two are warnings for the thread to answer.
# --------------------------------------------------------------------------
DOCS_BIG_CHANGE = 150          # added source lines that count as "more than a tweak"
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif")
UI_EXT = (".css", ".scss", ".svelte", ".tsx", ".jsx", ".vue", ".html")
CODE_EXT = (".lua", ".js", ".ts", ".tsx", ".jsx", ".svelte", ".vue")
NOT_SOURCE = ("node_modules/", "/dist/", "/build/", "dist/", "build/", "docs/", "tests/", "test/",
              ".github/", "/nxt-ui/", "vendor/", "tools/")


def _git(root, *args):
    r = subprocess.run(["git", "-C", root] + list(args), capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def _is_doc(rel):
    low = rel.lower()
    if low.endswith(IMAGE_EXT) or low == "claude.md":
        return False
    if low.startswith("docs/"):
        return True
    return "/" not in rel and (low.startswith("readme") or low.endswith((".md", ".html")))


def _is_changelog(rel):
    return os.path.basename(rel).lower().startswith(("changelog", "changes", "history", "release"))


def _is_source(rel):
    return not any(rel.startswith(x) or x in "/" + rel for x in NOT_SOURCE)


def cmd_docs(root, argv):
    base = None
    if "--base" in argv:
        i = argv.index("--base")
        base = argv[i + 1] if i + 1 < len(argv) else None
    if not base:
        ref = os.environ.get("GITHUB_BASE_REF")
        base = "origin/" + ref if ref else "origin/main"
    fork = (_git(root, "merge-base", base, "HEAD") or "").strip()
    if not fork:
        print("docs: cannot compare with %s (not fetched?) - skipped" % base)
        return 0
    names = (_git(root, "diff", "--name-only", fork, "HEAD") or "").split("\n")
    changed = [n for n in names if n]
    if not changed:
        print("docs: no changes against %s" % base)
        return 0
    docs = [n for n in changed if _is_doc(n)]
    # a changelog entry records that something changed; it does not document it
    reference = [n for n in docs if not _is_changelog(n)]
    # README images: in docs/, at the root, or wherever the README itself points (preview/, images/, ...)
    readme = next((n for n in os.listdir(root) if n.lower().startswith("readme")), None)
    readme_text = read(os.path.join(root, readme)) if readme else ""
    shown = set()
    for ref in re.findall(r"!\[[^\]]*\]\(\s*<?([^)\s>]+)", readme_text) + re.findall(r"<img\s[^>]*?src=[\"']([^\"']+)", readme_text):
        if not re.match(r"[a-z]+:", ref, re.I):
            shown.add(os.path.normpath(ref.split("#")[0].split("?")[0]).replace(os.sep, "/"))
    images = [n for n in changed if n.lower().endswith(IMAGE_EXT) and (n.startswith("docs/") or "/" not in n or n in shown)]

    # 1. exports, events, callbacks this resource provides
    old_raw = _git(root, "show", fork + ":contracts.json")
    new_path = os.path.join(root, "contracts.json")
    added, removed = [], []
    if old_raw and os.path.isfile(new_path):
        try:
            old, new = flat_provides(json.loads(old_raw)), flat_provides(json.loads(read(new_path)))
            added, removed = sorted(new - old), sorted(old - new)
        except ValueError:
            pass

    # 2. how the UI looks
    ui = [n for n in changed if n.lower().endswith(UI_EXT) and _is_source(n)]
    shows_images = bool(readme and re.search(r"!\[[^\]]*\]\([^)]+\)|<img\s", readme_text))

    # 3. size of the change
    big, new_files = 0, 0
    for line in (_git(root, "diff", "--numstat", "--diff-filter=AM", fork, "HEAD") or "").split("\n"):
        parts = line.split("\t")
        if len(parts) == 3 and parts[0].isdigit() and parts[2].lower().endswith(CODE_EXT) and _is_source(parts[2]):
            big += int(parts[0])
    for n in (_git(root, "diff", "--name-only", "--diff-filter=A", fork, "HEAD") or "").split("\n"):
        if n.lower().endswith(CODE_EXT) and _is_source(n):
            new_files += 1

    rc = 0
    if (added or removed) and not reference:
        what = ", ".join((["added " + a for a in added] + ["removed " + r for r in removed])[:6])
        print("::error::docs: this change alters what the resource provides (%s) but neither the README "
              "nor the developer reference was updated%s. Document it in the README or the developer "
              "reference." % (what, " (a changelog entry alone does not count)" if docs else ""))
        rc = 1
    if ui and shows_images and not images:
        print("::warning::docs: UI files changed (%s%s) and the README shows images, but no image was "
              "updated. If this changes how the UI looks, re-render the images it affects. If it is a "
              "fix with no visible change, ignore this."
              % (", ".join(ui[:3]), " ..." if len(ui) > 3 else ""))
    if (big >= DOCS_BIG_CHANGE or new_files) and not docs and not (added or removed):
        print("::warning::docs: this is more than a tweak (%d source lines added, %d new source file(s)) "
              "and no README or docs file was updated. A new feature or a major design change needs "
              "the docs updated; a bug fix does not, so ignore this if that is what it is."
              % (big, new_files))
    if rc == 0:
        print("docs: %d file(s) changed, %d docs, %d images; contract changes: %d"
              % (len(changed), len(docs), len(images), len(added) + len(removed)))
    return rc


# --------------------------------------------------------------------------
# line endings

EOL_SKIP = ("node_modules/", "/dist/", "/build/", "dist/", "build/")


def _git_bytes(root, *args):
    r = subprocess.run(["git", "-C", root] + list(args), capture_output=True)
    return r.stdout if r.returncode == 0 else None


def _eol_counts(data):
    crlf = data.count(b"\r\n")
    return crlf, data.count(b"\n") - crlf


def _eol_kind(crlf, lf):
    if crlf and lf:
        return "both"
    return "CRLF" if crlf else ("LF" if lf else "none")


def _eol_split(data):
    """[(text without its line ending, the ending)], the ending being b'\r\n', b'\n' or b''."""
    out = []
    for line in data.split(b"\n"):
        out.append((line[:-1], b"\r\n") if line.endswith(b"\r") else (line, b"\n"))
    text, _ = out[-1]
    out[-1] = (text, b"")              # what follows the last \n has no ending
    if out[-1] == (b"", b""):
        out.pop()
    return out


def _eol_restore(old, new):
    """`new` with the line endings of `old`: an unchanged line gets the ending it had,
    a new or changed line gets the kind most of the old file used."""
    import difflib
    crlf, lf = _eol_counts(old)
    major = b"\r\n" if crlf > lf else b"\n"
    a, b = _eol_split(old), _eol_split(new)
    ends = [major if e else b"" for _, e in b]
    sm = difflib.SequenceMatcher(None, [t for t, _ in a], [t for t, _ in b], autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            for k in range(i2 - i1):
                if b[j1 + k][1]:
                    ends[j1 + k] = a[i1 + k][1] or major
    return b"".join(t + e for (t, _), e in zip(b, ends))


def cmd_eol(root, argv):
    """A file keeps the line endings it has. Compares, for every file this branch modified or
    renamed, the blob at the merge base with the blob at HEAD (blobs, so no checkout setting
    can change the answer). New files, binary files and built UI folders are skipped, and so is
    a file in which nothing but the endings changed (a deliberate conversion)."""
    base, fix = None, "--fix" in argv
    if "--base" in argv:
        i = argv.index("--base")
        base = argv[i + 1] if i + 1 < len(argv) else None
    if not base:
        ref = os.environ.get("GITHUB_BASE_REF")
        base = "origin/" + ref if ref else "origin/main"
    fork = (_git(root, "merge-base", base, "HEAD") or "").strip()
    if not fork:
        print("eol: cannot compare with %s (not fetched?) - skipped" % base)
        return 0
    pairs = []
    raw = _git(root, "diff", "--name-status", "-M", "--diff-filter=MR", "-z", fork, "HEAD") or ""
    parts = [x for x in raw.split("\0") if x]
    i = 0
    while i < len(parts):
        if parts[i].startswith("R") and i + 2 < len(parts):
            pairs.append((parts[i + 1], parts[i + 2]))
            i += 3
        elif i + 1 < len(parts):
            pairs.append((parts[i + 1], parts[i + 1]))
            i += 2
        else:
            break
    bad, checked = [], 0
    for old_path, new_path in pairs:
        if any(new_path.startswith(x) or x in "/" + new_path for x in EOL_SKIP):
            continue
        old = _git_bytes(root, "show", "%s:%s" % (fork, old_path))
        new = _git_bytes(root, "show", "HEAD:%s" % new_path)
        if old is None or new is None or b"\0" in old[:8000] or b"\0" in new[:8000]:
            continue
        checked += 1
        oc, ol = _eol_counts(old)
        nc, nl = _eol_counts(new)
        ok, nk = _eol_kind(oc, ol), _eol_kind(nc, nl)
        if ok == "none" or nk == "none":
            continue
        if ok == "both":
            wrong = (oc > ol) != (nc > nl)
        else:
            wrong = nk != ok
        if not wrong:
            continue
        if old.replace(b"\r\n", b"\n") == new.replace(b"\r\n", b"\n"):
            # nothing but the endings changed: that is somebody converting the file on purpose
            # (putting a wrongly converted file back, say), not an edit that converted it by accident
            print("::notice file=%s::eol: %s went from %s to %s and nothing else in it changed; taken as deliberate"
                  % (new_path, new_path, ok, nk))
            continue
        bad.append(new_path)
        if fix:
            path = os.path.join(root, new_path)
            with open(path, "rb") as fh:
                cur = fh.read()
            with open(path, "wb") as fh:
                fh.write(_eol_restore(old, cur))
            print("eol: %s put back to %s (working tree; commit it)" % (new_path, ok))
        else:
            print("::error file=%s::eol: %s had %s line endings (%d CRLF, %d LF) and now has %s (%d CRLF, %d LF). "
                  "A file keeps the line endings it has: put them back with "
                  "`python3 .github/nxt/nxt_check.py eol --fix`, and change files with exact replacements "
                  "instead of writing them out whole." % (new_path, new_path, ok, oc, ol, nk, nc, nl))
    if not bad:
        print("eol: %d changed file(s) checked, line endings kept" % checked)
    return 1 if bad and not fix else 0


README_MIN_LINES = 15          # fewer non-empty lines than this is a stub, not a README
README_SECTIONS = (            # (what it is called in the message, words that show the README covers it)
    ("install or requirements", ("install", "setup", "set up", "requirement", "dependenc", "ensure ")),
    ("configuration", ("config",)),
)
README_API = ("export", "event", "callback")


def cmd_required(root):
    """The files every resource repo must have (WORKING.md, "Every resource repo has").
    A missing file is an error. A README that does not cover a required subject is a warning."""
    errors, warnings = [], []
    names = os.listdir(root)
    readme = next((n for n in names if n.lower().startswith("readme") and os.path.isfile(os.path.join(root, n))), None)
    if not readme:
        errors.append("there is no README. Every resource repo has one: what the resource is, its version, "
                      "install and requirements, configuration, and the exports and events it provides.")
    else:
        text = read(os.path.join(root, readme))
        low = text.lower()
        lines = [l for l in text.split("\n") if l.strip()]
        if "<!-- nxt:readme-skeleton -->" in text:
            errors.append("%s is still the skeleton the sync wrote. Replace every TODO and delete the marker "
                          "comment at the top." % readme)
        elif len(lines) < README_MIN_LINES:
            errors.append("%s has %d lines of content; that is a stub (fewer than %d)." % (readme, len(lines), README_MIN_LINES))
        for label, words in README_SECTIONS:
            if not any(w in low for w in words):
                warnings.append("%s does not seem to cover %s." % (readme, label))
        provides = set()
        cj = os.path.join(root, "contracts.json")
        if os.path.isfile(cj):
            try:
                provides = flat_provides(json.loads(read(cj)))
            except ValueError:
                pass
        if provides and not any(w in low for w in README_API):
            warnings.append("%s does not mention the exports, events or callbacks this resource provides (%d in "
                            "contracts.json)." % (readme, len(provides)))
    for need, why in (("CLAUDE.md", "the repo's instructions for its thread"),
                      ("contracts.json", "generated: python3 .github/nxt/nxt_check.py contracts"),
                      ("fxmanifest.lua", "a resource has a manifest")):
        if not os.path.isfile(os.path.join(root, need)):
            errors.append("%s is missing (%s)." % (need, why))
    manifest = os.path.join(root, "fxmanifest.lua")
    if os.path.isfile(manifest):
        mtext = read(manifest)
        if not re.search(r"^\s*version\s", mtext, re.M):
            warnings.append("fxmanifest.lua has no version line.")
        if re.search(r"^\s*(ui_page|loadscreen)\b", mtext, re.M) and not os.path.isfile(os.path.join(root, ".github", "nxt-shots.json")):
            warnings.append("this resource has a UI but no before/after recipe (.github/nxt-shots.json).")
    for w in warnings:
        print("::warning::required: " + w)
    for e in errors:
        print("::error::required: " + e)
    if not errors:
        print("required: all present%s" % ("" if not warnings else " (%d warning(s))" % len(warnings)))
    return 1 if errors else 0


def main(argv):
    if len(argv) < 2 or argv[1] not in ("lua", "contracts", "docs", "required", "eol"):
        print(__doc__)
        return 2
    root = os.getcwd()
    if argv[1] == "lua":
        return cmd_lua(root)
    if argv[1] == "docs":
        return cmd_docs(root, argv[2:])
    if argv[1] == "required":
        return cmd_required(root)
    if argv[1] == "eol":
        return cmd_eol(root, argv[2:])
    return cmd_contracts(root, "--check" in argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
