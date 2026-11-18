#!/bin/sh
# check-public-tree.sh — allow-list guard for everything AXYON publishes (#2532).
#
# Usage:
#   check-public-tree.sh [OPTIONS] DIR                    the public repository tree
#   check-public-tree.sh [OPTIONS] --archive TARBALL...   release archives
#   check-public-tree.sh [OPTIONS] --release-assets DIR   a release's asset directory
#
# Options:
#   --allowlist FILE       rules file (default: public-tree-allowlist.txt next to this script)
#   --allow-placeholders   accept the unstamped installer key and placeholder legal
#                          text (pre-release dry runs only)
#   --allow-unsigned       --release-assets without SHA256SUMS.minisig (dry runs only)
#
# The terms are LICENSE, LICENSE-BINARY, THIRD-PARTY-NOTICES and LICENSES/ from
# copy-licenses.sh: at the top of the public tree, under share/axyon/licenses/
# in archives. The guard checks they exist, are nonempty regular files and carry
# no placeholder marker; it never judges the wording. The standard-library
# source (share/axyon/stdlib-src/) ships under LICENSE-BINARY and has no
# licence file of its own (#3584).
# Tree mode: every file must match a `+` rule of [tree] and no `-` rule; no
# symlinks; no file over 5 MiB (binaries go to GitHub Releases, not git); no
# text file may match a [content] pattern; README.md, install.sh and the
# licence files must exist. `.git/` at the top is skipped.
# Archive mode: members live under one top directory named after the archive
# (`axyon-<version>-<triple>/`), relative paths without `..`, owned by 0:0,
# only regular files, directories and in-archive relative symlinks, each
# allowed by [archive].
# Release-assets mode: only [assets] files; archives share one version and are
# for supported triples; SHA256SUMS lists exactly the archives (and install.sh,
# if attached) with matching hashes; the signature is present; every archive
# passes archive mode.
# Exit 0 = clean, 1 = violation, 2 = usage error. Needs python3 (standard library only).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
ALLOWLIST="$HERE/public-tree-allowlist.txt"
MODE=tree
PLACEHOLDERS=0
UNSIGNED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --allowlist) ALLOWLIST="$2"; shift 2 ;;
        --allow-placeholders) PLACEHOLDERS=1; shift ;;
        --allow-unsigned) UNSIGNED=1; shift ;;
        --archive) MODE=archive; shift ;;
        --release-assets) MODE=assets; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "check-public-tree: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || { echo "check-public-tree: nothing to check (see --help)" >&2; exit 2; }
[ -f "$ALLOWLIST" ] || { echo "check-public-tree: allow-list $ALLOWLIST not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check-public-tree: python3 is required" >&2; exit 2; }

exec python3 -I - "$ALLOWLIST" "$MODE" "$PLACEHOLDERS" "$UNSIGNED" "$@" <<'PY'
import hashlib, os, re, stat, sys, tarfile

allowlist, mode, placeholders, unsigned = sys.argv[1], sys.argv[2], sys.argv[3] == "1", sys.argv[4] == "1"
targets = sys.argv[5:]
TRIPLES = ("x86_64-linux-gnu", "aarch64-linux-gnu", "aarch64-apple-darwin")
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?"
ARCHIVE_RE = re.compile(r"^axyon-(%s)-(%s)\.tar\.gz$" % (VERSION, "|".join(map(re.escape, TRIPLES))))
MAX_TREE_FILE = 5 * 1024 * 1024
PLACEHOLDER_KEY = re.compile(r"^AXYON_RELEASE_PUBKEY='__AXYON_", re.M)
PLACEHOLDER_LEGAL = ("AXYON-PLACEHOLDER-LEGAL", "AXYON-DRAFT-LICENSE")
LEGAL_FILES = ("LICENSE", "LICENSE-BINARY", "THIRD-PARTY-NOTICES")
ARCHIVE_LEGAL_DIR = "share/axyon/licenses/"
ARCHIVE_LEGAL_NAMES = frozenset(ARCHIVE_LEGAL_DIR + n for n in LEGAL_FILES)
# The guard's own files name the forbidden patterns; they are not content-scanned.
GUARD_FILES = ("scripts/check-public-tree.sh", "scripts/public-tree-allowlist.txt")
errors = []


def err(msg):
    errors.append(msg)


def glob_re(g):
    out, i = "", 0
    while i < len(g):
        if g.startswith("**/", i):
            out += "(?:[^/]+/)*"; i += 3
        elif g.startswith("**", i):
            out += ".*"; i += 2
        elif g[i] == "*":
            out += "[^/]*"; i += 1
        elif g[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(g[i]); i += 1
    return re.compile("^" + out + "$")


def load_rules(path):
    sections, cur = {}, None
    for n, raw in enumerate(open(path, encoding="utf-8"), 1):
        line = raw.rstrip("\n")
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^\[(\w+)\]$", s)
        if m:
            cur = sections.setdefault(m.group(1), {"allow": [], "deny": [], "content": []})
            continue
        if cur is None or s[:2] not in ("+ ", "- "):
            sys.stderr.write("check-public-tree: %s:%d: malformed rule %r\n" % (path, n, line))
            sys.exit(2)
        body = s[2:].strip()
        if cur is sections.get("content"):
            if s[0] != "-":
                sys.stderr.write("check-public-tree: %s:%d: [content] only takes `-` rules\n" % (path, n))
                sys.exit(2)
            cur["content"].append(re.compile(body))
        elif s[0] == "+":
            cur["allow"].append(glob_re(body))
        else:
            pat, _, unless = body.partition(" unless ")
            cur["deny"].append((pat.strip(), glob_re(pat.strip()), glob_re(unless.strip()) if unless else None))
    for need in ("tree", "archive", "assets", "content"):
        sections.setdefault(need, {"allow": [], "deny": [], "content": []})
    return sections


RULES = load_rules(allowlist)


def verdict(section, path):
    """None if `path` is allowed by `section`, else the reason."""
    r = RULES[section]
    for text, rx, unless in r["deny"]:
        if rx.match(path) and not (unless and unless.match(path)):
            return "denied by `- %s`" % text
    if not any(rx.match(path) for rx in r["allow"]):
        return "not on the [%s] allow-list" % section
    return None


def is_legal(rel):
    """True for the licence files and the files under LICENSES/ (tree or archive)."""
    base = rel[len(ARCHIVE_LEGAL_DIR):] if rel.startswith(ARCHIVE_LEGAL_DIR) else rel
    return base in LEGAL_FILES or base.startswith("LICENSES/")


def check_text(label, rel, data):
    if b"\0" in data[:8192]:
        return
    text = data.decode("utf-8", "replace")
    for rx in RULES["content"]["content"]:
        m = rx.search(text)
        if m:
            line = text.count("\n", 0, m.start()) + 1
            err("%s:%d: forbidden content /%s/ (%r)" % (label, line, rx.pattern, m.group(0)))
    if not placeholders:
        if rel.endswith("install.sh") and PLACEHOLDER_KEY.search(text):
            err("%s: the installer's release public key is still the placeholder (stamp it with prepare-public-tree.sh)" % label)
        if is_legal(rel) and any(p in text for p in PLACEHOLDER_LEGAL):
            err("%s: placeholder legal text (final terms come from Anyon legal)" % label)


def resolve_link(table, name):
    """Follow the symlink member `name` through `table` (member name -> linkname).

    Returns None when the final target stays inside the archive, else the reason.
    Every intermediate symlink (also those on directory components) is followed,
    so `a -> ..` followed by `b -> a/..` cannot slip past a lexical check.
    """
    if table[name].startswith("/"):
        return "absolute target"
    pending = name.split("/")[:-1] + table[name].split("/")
    resolved, hops = [], 0
    while pending:
        comp = pending.pop(0)
        if comp in ("", "."):
            continue
        if comp == "..":
            if len(resolved) <= 1:
                return "target leaves the archive"
            resolved.pop()
            continue
        resolved.append(comp)
        key = "/".join(resolved)
        if key in table:
            hops += 1
            if hops > 40:
                return "symlink loop"
            target = table[key]
            if target.startswith("/"):
                return "absolute target"
            resolved.pop()
            pending = target.split("/") + pending
    return None


def check_tree(root):
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        sys.stderr.write("check-public-tree: %s is not a directory\n" % root)
        sys.exit(2)
    for need in ("README.md", "install.sh") + LEGAL_FILES:
        path = os.path.join(root, need)
        if not os.path.isfile(path) or os.path.islink(path):
            err("%s: required regular file is missing" % need)
        elif need in LEGAL_FILES and os.path.getsize(path) == 0:
            err("%s: is empty" % need)
    lic_dir = os.path.join(root, "LICENSES")
    if not os.path.isdir(lic_dir) or os.path.islink(lic_dir):
        err("LICENSES: required directory is missing")
    else:
        nonempty = False
        for dirpath, _dirs, files in os.walk(lic_dir):
            for name in files:
                full = os.path.join(dirpath, name)
                rel = os.path.relpath(full, root).replace(os.sep, "/")
                if os.path.islink(full) or not os.path.isfile(full):
                    err("%s: licence entry must be a regular file" % rel)
                elif os.path.getsize(full) == 0:
                    err("%s: is empty" % rel)
                else:
                    nonempty = True
        if not nonempty:
            err("LICENSES: has no nonempty file")
    for dirpath, dirs, files in os.walk(root):
        if dirpath == root and ".git" in dirs:
            dirs.remove(".git")
        dirs.sort()
        for name in sorted(dirs + files):
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode):
                err("%s: symlinks are not allowed in the public tree" % rel)
                continue
            if stat.S_ISDIR(st.st_mode):
                continue
            if not stat.S_ISREG(st.st_mode):
                err("%s: not a regular file" % rel)
                continue
            why = verdict("tree", rel)
            if why:
                err("%s: %s" % (rel, why))
                continue
            if st.st_size > MAX_TREE_FILE:
                err("%s: %d bytes; binaries belong to GitHub Releases, not the tree" % (rel, st.st_size))
                continue
            if rel in GUARD_FILES:
                continue
            with open(full, "rb") as f:
                check_text(rel, rel, f.read())


def check_archive(path):
    base = os.path.basename(path)
    m = ARCHIVE_RE.match(base)
    if not m:
        err("%s: name is not axyon-<version>-<triple>.tar.gz for a supported triple" % base)
        return
    top = base[: -len(".tar.gz")]
    try:
        tar = tarfile.open(path, "r:gz")
        members = tar.getmembers()
    except (OSError, tarfile.TarError) as e:
        err("%s: unreadable archive: %s" % (base, e))
        return
    seen_release = False
    links = {t.name.rstrip("/"): t.linkname for t in members if t.issym()}
    counts = {}
    for t in members:
        counts[t.name.rstrip("/")] = counts.get(t.name.rstrip("/"), 0) + 1
    for dup in sorted(n for n, c in counts.items() if c > 1):
        # A later duplicate would overwrite the validated link on extraction (or
        # in `links` above), so every duplicate identity is refused outright.
        err("%s:%s: duplicate member name" % (base, dup))
    for ti in members:
        name = ti.name
        label = "%s:%s" % (base, name)
        parts = name.split("/")
        if name.startswith("/") or ".." in parts:
            err("%s: absolute or `..` path" % label); continue
        if any(c in ("", ".") for c in name.rstrip("/").split("/")):
            # resolve_link drops these components, so an aliased member name
            # would hide a link from its own table lookup.
            err("%s: noncanonical member name (empty or `.` component)" % label); continue
        if parts[0] != top:
            err("%s: outside the top directory %s/" % (label, top)); continue
        if ti.uid != 0 or ti.gid != 0:
            err("%s: owned by %d:%d, not 0:0" % (label, ti.uid, ti.gid))
        rel = "/".join(parts[1:])
        if ti.isdir():
            continue
        if ti.issym():
            why = resolve_link(links, name.rstrip("/"))
            if why:
                err("%s: symlink to %s rejected: %s" % (label, ti.linkname, why))
        elif not ti.isreg():
            err("%s: only regular files, directories and symlinks may ship" % label); continue
        why = verdict("archive", rel)
        if why:
            err("%s: %s" % (label, why)); continue
        if (rel == "RELEASE" or rel in ARCHIVE_LEGAL_NAMES) and not ti.isreg():
            # A symlink would pass the name check below without its target being read.
            err("%s: must be a regular file, not a symlink or directory" % label); continue
        if rel == "RELEASE":
            seen_release = True
            want = "version=%s\ntriple=%s\n" % (m.group(1), m.group(2))
            if tar.extractfile(ti).read().decode("utf-8", "replace") != want:
                err("%s: does not match the archive name" % label)
        elif ti.isreg():
            check_text(label, rel, tar.extractfile(ti).read())
    names = {"/".join(t.name.split("/")[1:]) for t in members if not t.isdir()}
    for need in ("RELEASE", "bin/axyon") + tuple(sorted(ARCHIVE_LEGAL_NAMES)):
        if need not in names:
            err("%s: missing %s" % (base, need))
    sizes = {"/".join(t.name.split("/")[1:]): t.size for t in members if t.isreg()}
    for need in sorted(ARCHIVE_LEGAL_NAMES):
        if sizes.get(need) == 0:
            err("%s: %s is empty" % (base, need))
    lic_prefix = ARCHIVE_LEGAL_DIR + "LICENSES/"
    for t in members:
        n = "/".join(t.name.split("/")[1:])
        if n.startswith(lic_prefix) and not t.isdir():
            if not t.isreg():
                err("%s:%s: licence entry must be a regular file" % (base, t.name))
            elif t.size == 0:
                err("%s:%s: is empty" % (base, t.name))
    if not any(n.startswith(lic_prefix) and sizes.get(n) for n in names):
        err("%s: %sLICENSES/ has no nonempty file" % (base, ARCHIVE_LEGAL_DIR))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_assets(d):
    if not os.path.isdir(d):
        sys.stderr.write("check-public-tree: %s is not a directory\n" % d)
        sys.exit(2)
    names = sorted(os.listdir(d))
    archives, versions = [], set()
    for n in names:
        full = os.path.join(d, n)
        if os.path.islink(full) or not os.path.isfile(full):
            err("%s: assets must be regular files" % n); continue
        why = verdict("assets", n)
        if why:
            err("%s: %s" % (n, why)); continue
        m = ARCHIVE_RE.match(n)
        if n.endswith(".tar.gz"):
            if not m:
                err("%s: not axyon-<version>-<triple>.tar.gz for a supported triple" % n); continue
            versions.add(m.group(1))
            archives.append(n)
            check_archive(full)
        if n == "install.sh":
            with open(full, "rb") as f:
                check_text(n, n, f.read())
    if not archives:
        err("no release archives in %s" % d)
    if len(versions) > 1:
        err("archives of several versions in one release: %s" % ", ".join(sorted(versions)))
    if "SHA256SUMS" not in names:
        err("SHA256SUMS is missing")
    else:
        listed = {}
        for line in open(os.path.join(d, "SHA256SUMS"), encoding="utf-8"):
            f = line.split()
            if len(f) != 2 or not re.match(r"^[0-9a-f]{64}$", f[0]):
                err("SHA256SUMS: malformed line %r" % line.rstrip()); continue
            listed[f[1].lstrip("*")] = f[0]
        expected = set(archives) | ({"install.sh"} & set(names))
        for n in sorted(expected - set(listed)):
            err("SHA256SUMS does not list %s" % n)
        for n in sorted(set(listed) - expected):
            err("SHA256SUMS lists %s, which is not attached" % n)
        for n in sorted(expected & set(listed)):
            if sha256(os.path.join(d, n)) != listed[n]:
                err("SHA256SUMS: hash mismatch for %s" % n)
    if "SHA256SUMS.minisig" not in names and not unsigned:
        err("SHA256SUMS.minisig is missing (sign with sign-release.sh)")


if mode == "tree":
    if len(targets) != 1:
        sys.stderr.write("check-public-tree: tree mode takes exactly one directory\n"); sys.exit(2)
    check_tree(targets[0])
elif mode == "archive":
    for t in targets:
        check_archive(t)
else:
    if len(targets) != 1:
        sys.stderr.write("check-public-tree: --release-assets takes exactly one directory\n"); sys.exit(2)
    check_assets(targets[0])

for e in errors:
    sys.stderr.write("check-public-tree: FAIL %s\n" % e)
if errors:
    sys.stderr.write("check-public-tree: %d violation(s)\n" % len(errors))
    sys.exit(1)
print("check-public-tree: ok (%s: %s)" % (mode, " ".join(targets)))
PY
