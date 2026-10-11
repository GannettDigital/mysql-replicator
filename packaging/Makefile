# Package previously compiled and verified executables. Compiler recipes live
# in separate files so package changes do not invalidate dependency layers.
VERSION ?= $(shell python3 tools/release_version.py --debian)
RELEASE_VERSION = $(shell cat VERSION)

# Build Debian package (.deb) from static musl binary
.PHONY: deb
deb:
	test "$(VERSION)" = "$$(python3 tools/release_version.py --debian)"
	test -f /out/mysql-replicator
	mkdir -p /out/deb
	rm -rf /out/deb-staging
	mkdir -p /out/deb-staging/DEBIAN
	mkdir -p /out/deb-staging/usr/bin
	mkdir -p /out/deb-staging/usr/share/doc/mysql-replicator
	mkdir -p /out/deb-staging/usr/share/doc/mysql-replicator/examples
	mkdir -p /out/deb-staging/lib/systemd/system
	mkdir -p /out/deb-staging/etc/mysql-replicator
	mkdir -p /out/deb-staging/var/lib/mysql-replicator
	cp /out/mysql-replicator /out/deb-staging/usr/bin/mysql-replicator
	chmod 0755 /out/deb-staging/usr/bin/mysql-replicator
	cp LICENSE NOTICE /out/deb-staging/usr/share/doc/mysql-replicator/
	cp -R /out/third-party /out/deb-staging/usr/share/doc/mysql-replicator/
	cp packaging/debian/mysql-replicator.service /out/deb-staging/lib/systemd/system/mysql-replicator.service
	chmod 0644 /out/deb-staging/lib/systemd/system/mysql-replicator.service
	sed 's#stateDirectory: ./replica-state#stateDirectory: /var/lib/mysql-replicator/state#' examples/apply.example.yaml > /out/deb-staging/etc/mysql-replicator/apply.example.yaml
	chmod 0644 /out/deb-staging/etc/mysql-replicator/apply.example.yaml
	for example in run.minimal.yaml replay.minimal.yaml; do \
		sed 's#stateDirectory: ./replica-state#stateDirectory: /var/lib/mysql-replicator/state#' examples/$$example > /out/deb-staging/usr/share/doc/mysql-replicator/examples/$$example; \
	done
	sed "s/@VERSION@/$(VERSION)/g" packaging/debian/control.in > /out/deb-staging/DEBIAN/control
	chmod 0644 /out/deb-staging/DEBIAN/control
	cp packaging/debian/conffiles /out/deb-staging/DEBIAN/conffiles
	chmod 0644 /out/deb-staging/DEBIAN/conffiles
	cp packaging/debian/postinst /out/deb-staging/DEBIAN/postinst
	chmod 0755 /out/deb-staging/DEBIAN/postinst
	cp packaging/debian/prerm /out/deb-staging/DEBIAN/prerm
	chmod 0755 /out/deb-staging/DEBIAN/prerm
	dpkg-deb -Zxz --build --root-owner-group /out/deb-staging /out/deb/mysql-replicator_$(VERSION)_amd64.deb
	cd /out/deb && sha256sum mysql-replicator_$(VERSION)_amd64.deb > mysql-replicator_$(VERSION)_amd64.deb.sha256
	dpkg-deb --info /out/deb/mysql-replicator_$(VERSION)_amd64.deb
	dpkg-deb --contents /out/deb/mysql-replicator_$(VERSION)_amd64.deb

.PHONY: release
release: deb
	mkdir -p /out/release /out/archive/mysql-replicator-$(RELEASE_VERSION)-linux-x86_64
	cp /out/mysql-replicator LICENSE NOTICE examples/apply.example.yaml examples/run.minimal.yaml examples/replay.minimal.yaml docs/INSTALL.md /out/archive/mysql-replicator-$(RELEASE_VERSION)-linux-x86_64/
	cp -R /out/third-party /out/archive/mysql-replicator-$(RELEASE_VERSION)-linux-x86_64/
	tar -C /out/archive -czf /out/release/mysql-replicator-$(RELEASE_VERSION)-linux-x86_64.tar.gz mysql-replicator-$(RELEASE_VERSION)-linux-x86_64
	cp /out/deb/*.deb /out/release/
	cp examples/apply.example.yaml examples/run.minimal.yaml examples/replay.minimal.yaml LICENSE NOTICE packaging/install.sh /out/release/
	cp -R /out/evidence /out/release/build-evidence
	tar -C /out/release -czf /out/release/build-evidence.tar.gz build-evidence
	rm -rf /out/release/build-evidence
	cd /out/release && sha256sum *.deb *.tar.gz *.yaml LICENSE NOTICE install.sh > SHA256SUMS
