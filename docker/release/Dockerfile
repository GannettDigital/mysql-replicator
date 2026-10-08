# The context contains a verified release archive, not source or build tools.
FROM scratch AS archive
ADD release.tar.gz /

FROM scratch
ARG VERSION
ARG REVISION
LABEL org.opencontainers.image.title="mysql-replicator" \
      org.opencontainers.image.source="https://github.com/GannettDigital/mysql-replicator" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
COPY --from=archive /mysql-replicator-${VERSION}-linux-x86_64/ /opt/mysql-replicator/
COPY --chown=65532:65532 rootfs/ /
USER 65532:65532
WORKDIR /var/lib/mysql-replicator
STOPSIGNAL SIGTERM
ENTRYPOINT ["/opt/mysql-replicator/mysql-replicator"]
CMD ["--help"]
