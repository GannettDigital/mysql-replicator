#!/bin/sh
# Install a versioned Linux binary; never initialize or change replication state.
set -eu
fail() { echo "mysql-replicator installer: $*" >&2; exit 1; }
usage() { echo 'Usage: sh install.sh [--version VERSION|latest] [--prefix /absolute/path]'; }
version=latest
prefix=${HOME:?HOME must be set}/.local
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--prefix)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            case "$1" in --version) version=$2 ;; --prefix) prefix=$2 ;; esac
            shift 2 ;;
        --help) usage; exit 0 ;;
        *) usage >&2; fail "unknown argument: $1" ;;
    esac
done
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'binaries are available only for Linux x86_64; other platforms must build from source'
case "$prefix" in /*) ;; *) fail '--prefix must be an absolute path' ;; esac
command -v curl >/dev/null || fail 'curl is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'
work=$(mktemp -d)
staging=
link=
cleanup() {
    rm -rf "$work"
    [ -z "$staging" ] || rm -rf "$staging"
    [ -z "$link" ] || rm -f "$link"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
if [ "$version" = latest ]; then
    command -v jq >/dev/null || fail 'jq is required to select the newest release; install jq or specify --version'
    # GitHub /releases/latest excludes prereleases. Include published betas,
    # then pin every download to the selected immutable version.
    page=1
    : > "$work/candidates.json"
    while :; do
        curl --fail --show-error --location --retry 3 \
            "https://api.github.com/repos/GannettDigital/mysql-replicator/releases?per_page=100&page=$page" \
            --output "$work/releases.json"
        count=$(jq -er 'if type == "array" then length else error("expected releases array") end' "$work/releases.json") || fail 'invalid GitHub releases response'
        jq -c '[.[] | select(.draft == false and .published_at != null)] | max_by(.published_at) // empty' \
            "$work/releases.json" >> "$work/candidates.json" || fail 'invalid GitHub release metadata'
        [ "$count" -eq 100 ] || break
        page=$((page + 1))
    done
    tag=$(jq -sr 'max_by(.published_at) | .tag_name // empty' "$work/candidates.json") || fail 'cannot select newest release'
    case "$tag" in v*) version=${tag#v} ;; *) fail 'no published versioned release is available' ;; esac
    echo "Selected newest published release: $tag (including prereleases)." >&2
fi
number='(0|[1-9][0-9]*)'
identifier='(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
printf '%s\n' "$version" | grep -Eq "^$number\.$number\.$number(-$identifier(\.$identifier)*)?$" || fail 'specify --version with an explicit SemVer (without v)'
# grep is line-oriented: reject embedded line breaks too.
[ "$(printf '%s' "$version" | wc -l | tr -d ' ')" = 0 ] || fail 'invalid version'
umask 022
mkdir -p "$prefix"
prefix=$(cd "$prefix" && pwd -P)
destination=$prefix/lib/mysql-replicator/$version
binary=$prefix/bin/mysql-replicator
[ ! -e "$destination" ] && [ ! -L "$destination" ] || fail "version already installed at $destination"
if [ -e "$binary" ] || [ -L "$binary" ]; then
    [ -L "$binary" ] && [ ! -d "$binary" ] || fail "refusing to replace unmanaged $binary"
    case "$(readlink "$binary")" in
        "$prefix"/lib/mysql-replicator/*/mysql-replicator) ;;
        *) fail "refusing to replace unmanaged $binary" ;;
    esac
fi
name=mysql-replicator-$version-linux-x86_64
url=https://github.com/GannettDigital/mysql-replicator/releases/download/v$version
curl --fail --show-error --location --retry 3 "$url/$name.tar.gz" --output "$work/$name.tar.gz"
curl --fail --show-error --location --retry 3 "$url/SHA256SUMS" --output "$work/SHA256SUMS"
awk -v asset="$name.tar.gz" '$2 == asset { print; count++ } END { if (count != 1) exit 1 }' "$work/SHA256SUMS" > "$work/selected.sha256" || fail 'archive missing or duplicated in SHA256SUMS'
(cd "$work" && sha256sum --check selected.sha256) || fail 'archive checksum mismatch'
tar -xzf "$work/$name.tar.gz" -C "$work"
[ -x "$work/$name/mysql-replicator" ] && [ -s "$work/$name/third-party/manifest.json" ] || fail 'incomplete release archive'
"$work/$name/mysql-replicator" --version | grep -F "mysql-replicator $version (" >/dev/null || fail 'binary version does not match requested release'
mkdir -p "$prefix/lib/mysql-replicator" "$prefix/bin"
staging=$(mktemp -d "$prefix/lib/mysql-replicator/.install-XXXXXX")
cp -R "$work/$name/." "$staging/"
chmod 0755 "$staging"
mv "$staging" "$destination"
staging=
link=$prefix/bin/.mysql-replicator-$$
ln -s "$destination/mysql-replicator" "$link"
mv -f "$link" "$binary"
link=
echo "Installed $binary ($version). Add $prefix/bin to PATH if needed."
echo "Example and notices: $destination. Configuration and state were not changed."
