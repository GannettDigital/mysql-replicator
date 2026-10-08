#!/bin/sh
# Install a versioned Linux binary; never initialize or change replication state.
set -eu
fail() { echo "mysql-replicator installer: $*" >&2; exit 1; }
usage() { echo 'Usage: sh install.sh --version VERSION [--prefix /absolute/path]'; }
version=
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
number='(0|[1-9][0-9]*)'
identifier='(0|[1-9][0-9]*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)'
printf '%s\n' "$version" | grep -Eq "^$number\.$number\.$number(-$identifier(\.$identifier)*)?$" || fail 'specify --version with an explicit SemVer (without v)'
# grep is line-oriented: reject embedded line breaks too.
[ "$(printf '%s' "$version" | wc -l | tr -d ' ')" = 0 ] || fail 'invalid version'
[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || fail 'binaries are available only for Linux x86_64; other platforms must build from source'
case "$prefix" in /*) ;; *) fail '--prefix must be an absolute path' ;; esac
command -v curl >/dev/null || fail 'curl is required'
command -v sha256sum >/dev/null || fail 'sha256sum is required'
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
