#!/bin/sh
set -eu
cd /release
sha256sum --check SHA256SUMS
mkdir /archive-test
tar -xzf mysql-replicator-*-linux-x86_64.tar.gz -C /archive-test
archive=$(find /archive-test -mindepth 1 -maxdepth 1 -type d)
cmp "$archive/mysql-replicator" /usr/bin/mysql-replicator
version=$(basename "$archive" | sed 's/^mysql-replicator-//; s/-linux-x86_64$//')
package_version=$(dpkg-query -W -f '${Version}' mysql-replicator)
expected_debian=$(printf '%s' "$version" | sed 's/-/~/')
test "$package_version" = "$expected_debian-1"
case "$version" in
    *-*) dpkg --compare-versions "$package_version" lt "${version%%-*}-1" ;;
esac
/usr/bin/mysql-replicator --version | grep -F "mysql-replicator $version ("
"$archive/mysql-replicator" --help >/dev/null
test -s "$archive/third-party/manifest.json"
test -s /usr/share/doc/mysql-replicator/third-party/manifest.json
test ! -e /var/lib/mysql-replicator/state
grep -q '^stateDirectory: /var/lib/mysql-replicator/state ' /etc/mysql-replicator/apply.example.yaml
grep -q '^User=mysql-replicator$' /lib/systemd/system/mysql-replicator.service
grep -q '^Restart=no$' /lib/systemd/system/mysql-replicator.service
# Check the service user can create private state, without starting replication.
su -s /bin/sh mysql-replicator -c 'umask 077; mkdir /var/lib/mysql-replicator/permission-test; rmdir /var/lib/mysql-replicator/permission-test'
# Install/upgrade leaves operator-owned configuration untouched.
cp /etc/mysql-replicator/apply.example.yaml /etc/mysql-replicator/apply.yaml
printf '\n# operator configuration\n' >> /etc/mysql-replicator/apply.yaml
cp /etc/mysql-replicator/apply.yaml /tmp/operator-config
chown root:mysql-replicator /etc/mysql-replicator/apply.yaml
chmod 0640 /etc/mysql-replicator/apply.yaml
dpkg -i /release/*.deb
cmp /tmp/operator-config /etc/mysql-replicator/apply.yaml
su -s /bin/sh mysql-replicator -c 'test -r /etc/mysql-replicator/apply.yaml'
# Run the actual installer and static binary against this build's release assets.
# Only the download transport is replaced; no network publication is needed.
mkdir /installer-bin
cat > /installer-bin/curl <<'SH'
#!/bin/sh
set -eu
while [ "$#" -gt 0 ]; do
    case "$1" in
        https://github.com/GannettDigital/mysql-replicator/releases/download/v*) url=$1; shift ;;
        --output) output=$2; shift 2 ;;
        --retry) shift 2 ;;
        --fail|--show-error|--location) shift ;;
        *) exit 2 ;;
    esac
done
cp "/release/${url##*/}" "$output"
SH
chmod 0755 /installer-bin/curl
PATH="/installer-bin:$PATH" sh /release/install.sh --version "$version" --prefix /installer-test
cmp /installer-test/bin/mysql-replicator /usr/bin/mysql-replicator
test -s "/installer-test/lib/mysql-replicator/$version/third-party/manifest.json"
/installer-test/bin/mysql-replicator --version
