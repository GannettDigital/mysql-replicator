.PHONY: build native-smoke
build:
	./scripts/build.sh
native-smoke:
	python3 tests/harness/native_smoke.py
