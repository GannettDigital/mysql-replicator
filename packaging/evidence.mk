.PHONY: evidence
evidence:
	file /out/packaging-probe /out/mysql-replicator > /out/evidence/elf.txt
	readelf -h -l -d /out/packaging-probe >> /out/evidence/elf.txt
	! readelf -l /out/packaging-probe | grep -q INTERP
	! readelf -d /out/packaging-probe | grep -q NEEDED
	! readelf -l /out/mysql-replicator | grep -q INTERP
	! readelf -d /out/mysql-replicator | grep -q NEEDED
	sha256sum /out/packaging-probe /out/mysql-replicator > /out/evidence/sha256.txt
	swift --version > /out/evidence/toolchains.txt
	rustc --version >> /out/evidence/toolchains.txt
	cp Package.resolved packaging/rust/Cargo.lock /out/evidence/
	cp Package.resolved /out/evidence/production-Package.resolved
	cp rust/Cargo.lock /out/evidence/production-Cargo.lock
	cp /root/.swiftpm/swift-sdks/swift-6.2.1-RELEASE_static-linux-0.0.1.artifactbundle/sbom.spdx.json /out/evidence/sdk-sbom.spdx.json
	python3 packaging/collect_notices.py

