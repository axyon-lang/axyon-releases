#!/bin/sh
# AXYON installer (#2532).
#
#   curl -fsSL https://github.com/axyon-lang/axyon-releases/releases/latest/download/install.sh | sh
#   curl -fsSL .../install.sh | sh -s -- --version 0.1.0 --prefix "$HOME/.local"
#
# Private hosting (internal alpha testers, #3585): the same script downloads
# with curl and credentials; see "Authentication" below. Anonymous downloads
# stay the default.
#
# Downloads the release archive for this platform plus SHA256SUMS and its
# minisign signature, verifies the signature (with the release public key
# embedded below) and the archive checksum, and installs into a prefix
# (default ~/.axyon). Nothing is installed unless both checks pass.
#
# Options:
#   --version V                 install release V (e.g. 0.1.0), `latest` (default) or `nightly`
#   --prefix DIR                install prefix (default: $AXYON_INSTALL_PREFIX or ~/.axyon)
#   --base-url URL              release base URL (default: GitHub Releases of axyon-lang/axyon-releases);
#                               https:// or file:// only
#   --source S                  auto (default), public or github-private; github-private reads
#                               a private GitHub repository through the API asset endpoint
#   --public-key KEY            minisign public key (overrides the embedded release key)
#   --insecure-skip-signature   install without verifying the signature (the checksum is
#                               still verified; integrity then rests on the download channel)
#   --keep-old                  keep previously installed releases next to the new one
#   --uninstall                 remove what this installer installed under the prefix
#   --print-target              print the detected platform triple and exit
#   -h, --help                  show this help
#
# Authentication (curl only; wget is the anonymous-only fallback). The first
# match wins:
#   AXYON_INSTALL_NETRC=FILE    curl --netrc-file FILE (Nexus basic auth, or a GitHub token as password)
#   AXYON_INSTALL_TOKEN         bearer token, for any host
#   GH_TOKEN / GITHUB_TOKEN     bearer token, only when the base URL is a github.com release URL
#   ~/.netrc                    used when --base-url is not the default or --source github-private
# A credential is never put in argv, logs or files: headers are passed to curl
# as a config on stdin (curl -K -), and --netrc-file names a file you own.
# With a token and a github.com base URL, --source auto selects github-private.
#
# Layout: the release unpacks to <prefix>/libexec/axyon/<version>-<triple>/
# (a complete install prefix: bin/, lib/axyon/, share/axyon/) and small
# wrapper scripts in <prefix>/bin exec the active release. An upgrade unpacks
# the new release next to the old one and switches the wrappers by atomic
# rename, so a failed upgrade leaves the previous release working.
#
# The terms of use are LICENSE-BINARY in the release (share/axyon/licenses/,
# with third-party notices); the installer only points to them.
#
# Exit status: 0 on success, 1 on any failure (nothing is half-installed), 2 on usage errors.
set -eu

# minisign public key of AXYON releases; stamped by prepare-public-tree.sh at
# publish time. The placeholder is refused (unless --public-key is given).
AXYON_RELEASE_PUBKEY='RWRZLF8DY/Lm0u/H7zyN8WWCE+xoI4YYYLQ1fTa/K6RuwzIHm8zMujGb'
DEFAULT_BASE_URL='https://github.com/axyon-lang/axyon-releases/releases'
GITHUB_API='https://api.github.com'
WRAPPER_MARK='# axyon-installer-wrapper'
MIN_GLIBC='2.28'

say() { printf 'axyon-install: %s\n' "$*"; }
warn() { printf 'axyon-install: warning: %s\n' "$*" >&2; }
die() { printf 'axyon-install: error: %s\n' "$*" >&2; exit 1; }
usage_error() { printf 'axyon-install: %s (see --help)\n' "$*" >&2; exit 2; }

VERSION="${AXYON_INSTALL_VERSION:-latest}"
PREFIX="${AXYON_INSTALL_PREFIX:-}"
BASE_URL="${AXYON_INSTALL_BASE_URL:-$DEFAULT_BASE_URL}"
SOURCE="${AXYON_INSTALL_SOURCE:-auto}"
PUBKEY=''
SKIP_SIG=0
KEEP_OLD=0
UNINSTALL=0
PRINT_TARGET=0

usage() {
    cat <<'EOF'
Usage: install.sh [--version V|latest|nightly] [--prefix DIR] [--base-url URL]
                  [--source auto|public|github-private] [--public-key KEY] [--insecure-skip-signature] [--keep-old]
                  [--uninstall] [--print-target]

Installs AXYON for this platform (x86_64-linux-gnu, aarch64-linux-gnu,
aarch64-apple-darwin) into DIR (default ~/.axyon) after verifying the
minisign signature of SHA256SUMS and the archive checksum.
Private hosting: AXYON_INSTALL_NETRC, AXYON_INSTALL_TOKEN, GH_TOKEN or
GITHUB_TOKEN supply credentials to curl (never on the command line).
Terms of use: LICENSE-BINARY in the release (share/axyon/licenses/).
EOF
}

need_arg() { [ "$2" -ge 2 ] || usage_error "$1 needs a value"; }
while [ $# -gt 0 ]; do
    case "$1" in
        --version) need_arg "$1" $#; VERSION="$2"; shift 2 ;;
        --version=*) VERSION="${1#*=}"; shift ;;
        --prefix) need_arg "$1" $#; PREFIX="$2"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --base-url) need_arg "$1" $#; BASE_URL="$2"; shift 2 ;;
        --base-url=*) BASE_URL="${1#*=}"; shift ;;
        --source) need_arg "$1" $#; SOURCE="$2"; shift 2 ;;
        --source=*) SOURCE="${1#*=}"; shift ;;
        --public-key) need_arg "$1" $#; PUBKEY="$2"; shift 2 ;;
        --public-key=*) PUBKEY="${1#*=}"; shift ;;
        --insecure-skip-signature) SKIP_SIG=1; shift ;;
        --keep-old) KEEP_OLD=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --print-target) PRINT_TARGET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage_error "unknown option: $1" ;;
    esac
done

# --- platform detection -----------------------------------------------------

# version_lt A B: true when dotted version A < B (numeric components).
version_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        na = split(a, x, "."); nb = split(b, y, ".")
        n = na > nb ? na : nb
        for (i = 1; i <= n; i++) {
            xi = (i <= na) ? x[i] + 0 : 0; yi = (i <= nb) ? y[i] + 0 : 0
            if (xi < yi) exit 0
            if (xi > yi) exit 1
        }
        exit 1
    }'
}

check_linux_libc() {
    if command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
        die "musl libc is not supported; AXYON releases need glibc >= $MIN_GLIBC"
    fi
    glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')" || glibc=''
    if [ -z "$glibc" ]; then
        warn "could not determine the glibc version; AXYON needs glibc >= $MIN_GLIBC"
    elif version_lt "$glibc" "$MIN_GLIBC"; then
        die "glibc $glibc is too old; AXYON releases need glibc >= $MIN_GLIBC"
    fi
}

detect_target() {
    os="$(uname -s)" || die "uname -s failed"
    arch="$(uname -m)" || die "uname -m failed"
    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64) TARGET=x86_64-linux-gnu ;;
                aarch64|arm64) TARGET=aarch64-linux-gnu ;;
                *) die "unsupported Linux architecture '$arch' (supported: x86_64, aarch64)" ;;
            esac
            check_linux_libc
            ;;
        Darwin)
            # A shell running under Rosetta reports x86_64 on Apple silicon.
            if [ "$arch" = x86_64 ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
                arch=arm64
            fi
            case "$arch" in
                arm64|aarch64) TARGET=aarch64-apple-darwin ;;
                *) die "unsupported macOS architecture '$arch' (only Apple silicon, arm64, is supported)" ;;
            esac
            ;;
        *) die "unsupported operating system '$os' (supported: Linux x86_64/aarch64, macOS arm64)" ;;
    esac
}

# --- prefix -----------------------------------------------------------------

resolve_prefix() {
    if [ -z "$PREFIX" ]; then
        [ -n "${HOME:-}" ] || die "HOME is not set; pass --prefix"
        PREFIX="$HOME/.axyon"
    fi
    case "$PREFIX" in
        *"'"*|*'
'*) die "the prefix must not contain quotes or newlines: $PREFIX" ;;
    esac
    mkdir -p "$PREFIX" || die "cannot create $PREFIX"
    PREFIX="$(cd "$PREFIX" && pwd -P)" || die "cannot enter $PREFIX"
    RELEASES="$PREFIX/libexec/axyon"
}

is_our_wrapper() { [ -f "$1" ] && sed -n 2p "$1" 2>/dev/null | grep -q "^$WRAPPER_MARK "; }

uninstall() {
    resolve_prefix
    removed=0
    if [ -d "$PREFIX/bin" ]; then
        for w in "$PREFIX"/bin/*; do
            if is_our_wrapper "$w"; then rm -f "$w"; say "removed $w"; removed=1; fi
        done
    fi
    if [ -d "$RELEASES" ]; then rm -rf "$RELEASES"; say "removed $RELEASES"; removed=1; fi
    rmdir "$PREFIX/libexec" "$PREFIX/bin" "$PREFIX" 2>/dev/null || true
    [ "$removed" = 1 ] || say "nothing to uninstall under $PREFIX"
    say "remove $PREFIX/bin from PATH in your shell profile if you added it"
}

# --- download and verification ----------------------------------------------

AUTH_MODE=none # none, netrc or token
AUTH_TOKEN=''
AUTH_NETRC=''
GH_REPO=''

# github_repo_of BASE_URL: print OWNER/REPO for a github.com release base URL.
github_repo_of() {
    case "$1" in
        https://github.com/*/*/releases) ;;
        *) return 1 ;;
    esac
    r="${1#https://github.com/}"
    r="${r%/releases}"
    case "$r" in */*/*|/*|*/|*[!A-Za-z0-9._/-]*) return 1 ;; esac
    printf '%s' "$r"
}

# resolve_auth: choose the credential and the download source (see the header).
resolve_auth() {
    case "$SOURCE" in auto|public|github-private) ;; *) usage_error "invalid --source '$SOURCE' (auto, public or github-private)" ;; esac
    case "$BASE_URL" in
        *://*@*) die "--base-url must not contain credentials; use AXYON_INSTALL_TOKEN or AXYON_INSTALL_NETRC" ;;
    esac
    GH_REPO="$(github_repo_of "$BASE_URL")" || GH_REPO=''
    if [ -n "${AXYON_INSTALL_NETRC:-}" ]; then
        [ -f "$AXYON_INSTALL_NETRC" ] || die "AXYON_INSTALL_NETRC does not name a file"
        AUTH_MODE=netrc; AUTH_NETRC="$AXYON_INSTALL_NETRC"
    elif [ -n "${AXYON_INSTALL_TOKEN:-}" ]; then
        AUTH_MODE=token; AUTH_TOKEN="$AXYON_INSTALL_TOKEN"
    elif [ -n "$GH_REPO" ] && [ "$SOURCE" != public ] && [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
        AUTH_MODE=token; AUTH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
    elif [ -n "${HOME:-}" ] && [ -f "$HOME/.netrc" ] \
        && { [ "$BASE_URL" != "$DEFAULT_BASE_URL" ] || [ "$SOURCE" = github-private ]; }; then
        AUTH_MODE=netrc; AUTH_NETRC="$HOME/.netrc"
    fi
    if [ "$AUTH_MODE" = token ]; then
        # The token goes into a quoted curl config line; refuse anything that could break out of it.
        case "$AUTH_TOKEN" in
            *[!A-Za-z0-9._~+/=-]*) die "the token has unexpected characters (expected a GitHub or Nexus token)" ;;
        esac
    fi
    if [ "$SOURCE" = auto ]; then
        if [ "$AUTH_MODE" = token ] && [ -n "$GH_REPO" ]; then SOURCE=github-private; else SOURCE=public; fi
    fi
    if [ "$SOURCE" = github-private ]; then
        [ -n "$GH_REPO" ] || die "--source github-private needs --base-url https://github.com/<owner>/<repo>/releases"
        [ "$AUTH_MODE" != none ] || die "authentication required: a private GitHub repository needs a token or netrc entry.
  Set AXYON_INSTALL_TOKEN (or GH_TOKEN/GITHUB_TOKEN), or AXYON_INSTALL_NETRC=<file with a github.com or api.github.com entry>."
    fi
}

# auth_config ACCEPT: curl config lines (read from stdin by `curl -K -`, so a
# credential never appears in argv). printf is a shell builtin.
auth_config() {
    [ -z "$1" ] || printf 'header = "Accept: %s"\n' "$1"
    [ "$AUTH_MODE" != token ] || printf 'header = "Authorization: Bearer %s"\n' "$AUTH_TOKEN"
    return 0
}

fetch() { # URL DEST [ACCEPT]
    case "$1" in
        file://*)
            cp "${1#file://}" "$2" 2>/dev/null || die "download failed: $1"
            ;;
        https://*)
            hint=''
            [ "$AUTH_MODE" != none ] || hint="
  if the release is private, set AXYON_INSTALL_TOKEN or AXYON_INSTALL_NETRC (see --help)"
            if command -v curl >/dev/null 2>&1; then
                if [ "$AUTH_MODE" = none ] && [ -z "${3:-}" ]; then
                    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1$hint"
                elif [ "$AUTH_MODE" = netrc ]; then
                    auth_config "${3:-}" | curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 \
                        --netrc-file "$AUTH_NETRC" -K - -o "$2" "$1" || die "download failed: $1"
                else
                    auth_config "${3:-}" | curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 \
                        -K - -o "$2" "$1" || die "download failed: $1$hint"
                fi
            elif [ "$AUTH_MODE" != none ] || [ -n "${3:-}" ]; then
                die "authenticated downloads need curl (wget is the anonymous fallback)"
            elif command -v wget >/dev/null 2>&1; then
                wget --https-only -q -O "$2" "$1" || die "download failed: $1$hint"
            else
                die "need curl or wget to download $1"
            fi
            ;;
        *) die "refusing non-https URL: $1" ;;
    esac
}

# gh_release_json: the release record for $VERSION, from the GitHub API.
gh_release_json() {
    case "$VERSION" in
        latest) ep='releases/latest' ;;
        nightly) ep='releases/tags/nightly' ;;
        *) ep="releases/tags/v$VERSION" ;;
    esac
    fetch "$GITHUB_API/repos/$GH_REPO/$ep" "$TMP/release.json" 'application/vnd.github+json'
}

# fetch_asset NAME DEST: one release asset, from the download URLs or the API.
fetch_asset() {
    if [ "$SOURCE" != github-private ]; then fetch "$url_dir/$1" "$2"; return; fi
    api_url="$(tr '{},' '\n\n\n' <"$TMP/release.json" | awk -v want="$1" '
        /"url" *: *"[^"]*\/releases\/assets\/[0-9]+" *$/ { u = $0; sub(/^.*"url" *: *"/, "", u); sub(/" *$/, "", u); next }
        /^ *"name" *: *"/ { n = $0; sub(/^ *"name" *: *"/, "", n); sub(/" *$/, "", n)
            if (n == want && u != "") { print u; exit } }')"
    [ -n "$api_url" ] || die "the release has no asset named $1"
    case "$api_url" in
        "$GITHUB_API/repos/$GH_REPO/releases/assets/"*) ;;
        *) die "unexpected asset URL in the release record: $api_url" ;;
    esac
    fetch "$api_url" "$2" 'application/octet-stream'
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 -r "$1" | awk '{print $1}'
    else
        die "need sha256sum, shasum or openssl to verify the download"
    fi
}

# verify_signature SUMS SIG: minisign signature of SUMS; prints the trusted comment.
verify_signature() {
    key="${PUBKEY:-$AXYON_RELEASE_PUBKEY}"
    case "$key" in
        __AXYON_*) die "this installer has no release public key embedded; download install.sh from the release page, or pass --public-key" ;;
    esac
    if ! command -v minisign >/dev/null 2>&1; then
        die "minisign is required to verify the release signature.
  Install it (macOS: brew install minisign; Debian/Ubuntu: sudo apt install minisign;
  other: https://jedisct1.github.io/minisign/) and re-run, or pass
  --insecure-skip-signature to rely on the checksum and the download channel only."
    fi
    out="$(minisign -V -P "$key" -m "$1" -x "$2" 2>&1)" \
        || die "signature verification FAILED for SHA256SUMS; not installing.
$out"
    printf '%s\n' "$out" | sed -n 's/^Trusted comment: //p' | head -n 1
}

TMP=''
stage=''
cleanup() {
    [ -z "$TMP" ] || rm -rf "$TMP"
    [ -z "$stage" ] || rm -rf "$stage"
}

valid_version() { printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; }

install_release() {
    detect_target
    resolve_prefix
    case "$BASE_URL" in https://*|file://*) ;; *) die "--base-url must be https:// or file://: $BASE_URL" ;; esac
    BASE_URL="${BASE_URL%/}"
    resolve_auth
    case "$VERSION" in
        latest) url_dir="$BASE_URL/latest/download" ;;
        nightly) url_dir="$BASE_URL/download/nightly" ;;
        *)
            VERSION="${VERSION#v}"
            valid_version "$VERSION" || usage_error "invalid version '$VERSION' (expected X.Y.Z[-pre], latest or nightly)"
            url_dir="$BASE_URL/download/v$VERSION"
            ;;
    esac

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/axyon-install.XXXXXX")" || die "mktemp failed"
    trap cleanup EXIT
    trap 'exit 1' INT TERM HUP

    if [ "$SOURCE" = github-private ]; then
        say "platform $TARGET; fetching release '$VERSION' of $GH_REPO through the GitHub API ($AUTH_MODE auth)"
        gh_release_json
    else
        say "platform $TARGET; fetching release '$VERSION' from $url_dir"
    fi
    fetch_asset SHA256SUMS "$TMP/SHA256SUMS"
    comment=''
    if [ "$SKIP_SIG" = 1 ]; then
        warn "--insecure-skip-signature: the release signature is NOT verified"
    else
        fetch_asset SHA256SUMS.minisig "$TMP/SHA256SUMS.minisig"
        comment="$(verify_signature "$TMP/SHA256SUMS" "$TMP/SHA256SUMS.minisig")"
        say "signature verified"
    fi

    # The archive for this platform, from the (now trusted) checksum list.
    matches="$(awk -v t="$TARGET" '
        NF == 2 && $1 ~ /^[0-9a-f]+$/ && length($1) == 64 {
            n = $2; sub(/^\*/, "", n)
            suf = "-" t ".tar.gz"
            if (index(n, "axyon-") == 1 && length(n) > length(suf) + 6 \
                && substr(n, length(n) - length(suf) + 1) == suf) print $1 " " n
        }' "$TMP/SHA256SUMS")"
    count="$(printf '%s' "$matches" | grep -c . || true)"
    [ "$count" = 1 ] || die "SHA256SUMS lists $count archives for $TARGET (expected exactly one)"
    want_sum="${matches%% *}"
    archive="${matches#* }"
    rel_version="${archive#axyon-}"
    rel_version="${rel_version%-"$TARGET".tar.gz}"
    valid_version "$rel_version" || die "malformed archive name in SHA256SUMS: $archive"
    case "$VERSION" in
        latest|nightly) ;;
        *) [ "$rel_version" = "$VERSION" ] || die "SHA256SUMS is for $rel_version, not the requested $VERSION" ;;
    esac
    if [ "$SKIP_SIG" = 0 ] && [ "$comment" != "axyon $rel_version" ]; then
        die "the signature's trusted comment '$comment' does not name release $rel_version"
    fi

    fetch_asset "$archive" "$TMP/$archive"
    got_sum="$(sha256_of "$TMP/$archive")"
    [ "$got_sum" = "$want_sum" ] || die "checksum mismatch for $archive (expected $want_sum, got $got_sum); not installing"
    say "checksum verified for $archive"

    # Every member must live under the single top directory; no absolute paths or `..`.
    top="axyon-$rel_version-$TARGET"
    tar -tzf "$TMP/$archive" >"$TMP/members" || die "cannot read $archive"
    bad="$(awk -v top="$top" '
        { p = $0; sub(/\/$/, "", p) }
        p != top && index(p, top "/") != 1 { print; next }
        p ~ /(^|\/)\.\.(\/|$)/ { print }' "$TMP/members" | head -n 3)"
    [ -z "$bad" ] || die "archive has unexpected members (e.g. $bad); not installing"

    mkdir -p "$RELEASES" "$PREFIX/bin"
    stage="$RELEASES/.staging.$$"
    rm -rf "$stage"; mkdir "$stage"
    tar -xzf "$TMP/$archive" -C "$stage" || die "extraction failed"
    new="$stage/$top"
    grep -qx "version=$rel_version" "$new/RELEASE" 2>/dev/null && grep -qx "triple=$TARGET" "$new/RELEASE" \
        || die "archive RELEASE metadata does not match $rel_version/$TARGET"
    [ -x "$new/bin/axyon" ] || die "archive has no bin/axyon"

    # Refuse to clobber a file in <prefix>/bin that this installer did not write.
    for b in "$new"/bin/*; do
        w="$PREFIX/bin/${b##*/}"
        if [ -e "$w" ] && ! is_our_wrapper "$w"; then
            die "$w exists and was not installed by this script; remove it or choose another --prefix"
        fi
    done

    id="$rel_version-$TARGET"
    dest="$RELEASES/$id"
    if [ -d "$dest" ]; then
        rm -rf "$RELEASES/.old.$$"; mv "$dest" "$RELEASES/.old.$$"
    fi
    mv "$new" "$dest"
    rm -rf "$stage" "$RELEASES/.old.$$"
    stage=''

    # Switch the wrappers: each is written beside its final name and renamed.
    for b in "$dest"/bin/*; do
        name="${b##*/}"
        tmpw="$PREFIX/bin/.$name.tmp.$$"
        {
            printf '#!/bin/sh\n%s (do not edit; re-run install.sh to change)\n' "$WRAPPER_MARK"
            printf "exec '%s' \"\$@\"\n" "$dest/bin/$name"
        } >"$tmpw"
        chmod 755 "$tmpw"
        mv -f "$tmpw" "$PREFIX/bin/$name"
    done
    # Wrappers for tools the new release no longer ships.
    for w in "$PREFIX"/bin/*; do
        if is_our_wrapper "$w" && [ ! -e "$dest/bin/${w##*/}" ]; then rm -f "$w"; fi
    done
    printf '%s\n' "$id" >"$RELEASES/.active.$$" && mv -f "$RELEASES/.active.$$" "$RELEASES/active"

    if [ "$KEEP_OLD" = 0 ]; then
        for d in "$RELEASES"/*; do
            if [ -d "$d" ] && [ "$d" != "$dest" ]; then rm -rf "$d"; fi
        done
    fi

    say "installed AXYON $rel_version ($TARGET) into $dest"
    say "terms of use: $dest/share/axyon/licenses/LICENSE-BINARY"
    case ":${PATH:-}:" in
        *":$PREFIX/bin:"*) say "run: axyon --version" ;;
        *)
            say "add $PREFIX/bin to your PATH, e.g. in ~/.profile, ~/.bashrc or ~/.zshrc:"
            printf '    export PATH="%s/bin:$PATH"\n' "$PREFIX"
            say "fish: fish_add_path $PREFIX/bin"
            ;;
    esac
    say "to uninstall: sh install.sh --uninstall --prefix \"$PREFIX\" (or delete $PREFIX/libexec/axyon and the axyon* wrappers in $PREFIX/bin)"
}

if [ "$PRINT_TARGET" = 1 ]; then detect_target; printf '%s\n' "$TARGET"; exit 0; fi
if [ "$UNINSTALL" = 1 ]; then uninstall; exit 0; fi
install_release
