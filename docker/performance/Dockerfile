# Load generator only; the replicator continues to use its static release build.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates sysbench=1.0.20+ds-6build2 \
    && rm -rf /var/lib/apt/lists/*
COPY workload.lua /workload.lua
ENTRYPOINT ["sysbench", "/workload.lua"]
