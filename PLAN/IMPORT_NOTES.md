# Imported planning documents

The three `REPLICATOR_*.md` documents were approved before this repository was created and copied without changing their technical content from the sibling `maxwell-mysql-consumer` workspace on 2026-09-29. They were untracked there; that repository's tracked HEAD was `ea009346c13c780381f9434106de534deee69973` at import. Their historical baseline and test results belong to that workspace.

References to `.upstream/`, `artifacts/replicator-codec-research/`, previous commits, Maxwell code and prior build images in those documents refer to the original workspace. Research clones, binaries and ignored evidence were not copied into this repository. The original Phase 5 report is included as historical context; its relative implementation links refer to the original project. See IMPLEMENTATION_STATUS.md for work actually completed here.

The MySQL 5.7 Dockerfile is copied from that workspace's `docker/mysql57/Dockerfile`; its setpriv entrypoint adjustment permits the amd64 fixture to run under Apple Silicon emulation. The selected MySQL images are fixtures, not production version recommendations.
