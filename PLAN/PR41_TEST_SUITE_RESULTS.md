# PR #41 result review

Compare PR #40 run 38165244447 with PR #41 run 38193142028. Both use attempt 1 and expanded full coverage. PR #41 tested merge commit c1ce9e430017b449c14b193a1891ea9bf41dfc0b, head 523a8077defb151087097e7a4068959d7fdb9583.

All checks passed. Both runs completed 718 catalog obligations, 227 integration jobs, and 130 coverage collections. All shard IDs and selections match. The release matrix still has 111 jobs. The coverage matrix still has 116 jobs.

| Measurement | PR #40 | PR #41 | Change |
|---|---:|---:|---:|
| Release shard minutes | 374.5 | 313.4 | -16.3% |
| Coverage shard minutes | 413.1 | 343.9 | -16.7% |
| Completed runner-minutes in report | 913.9 | 804.5 | -12.0% |
| Recorded job span, minutes | 62.65 | 60.17 | -4.0% |
| Release integration jobs over five minutes | 17 | 2 | -15 jobs |
| Coverage integration jobs over five minutes | 24 | 5 | -19 jobs |

The recorded job span starts at the first job and ends at the last completed job in the measurement report. It is not the full workflow duration. The report is collected before all final reporting work ends. PR #41 ran from 01:45:44 to 02:46:35 UTC on 2026-10-12, about 60.9 minutes.

## Test-area results

| Release area | PR #40 minutes | PR #41 minutes | Change |
|---|---:|---:|---:|
| DML | 29.3 | 18.0 | -38.5% |
| Indexes | 100.6 | 73.4 | -27.1% |
| DDL | 52.5 | 39.5 | -24.8% |
| Foreign keys | 7.3 | 5.6 | -23.2% |
| Database | 19.3 | 15.3 | -21.0% |
| Bootstrap | 56.1 | 54.8 | -2.4% |
| Ordered DDL | 22.4 | 23.3 | +3.9% |
| Reconnect | 17.8 | 18.4 | +3.5% |

The largest gains occur where SharedCorrectness.compare uses grouped metadata reads. Bootstrap and reconnect use other paths. Small increases and decreases in those areas can reflect run variation. These are two runs, not a repeated timing experiment.

## SQL client measurements

The release run reports 70,402 calls, including 8,694 metadata batches with 52,164 queries. These batches avoid 43,470 separate client launches. The coverage run avoids another 46,230 launches. This calculation compares each measured batch with the previous one-call-per-query implementation. PR #40 did not collect client counters, so it is not a measured before/after total-call comparison.

Four client failures appear in the expanded report. They occur in the foreign-key suite: one per InnoDB profile and image. The suite deliberately issues a parent DELETE that must fail with MySQL error 1451. All those scenarios passed. A failed client-call counter does not mean a failed test.

## Coverage comparison

- Unit coverage: unchanged, 5,644 / 7,469 lines.
- Integration coverage: 6,814 to 6,811 / 7,469 lines.
- Combined coverage: unchanged, 7,255 / 7,469 lines, 97.13%.

The integration difference is four lost lines and one added line in SourceTransportError.swift. Lines 30–33 handle ChannelError. Line 38 handles NIOSSLError.uncleanShutdown. In PR #40, only the forward gtid-full reconnect shard reached the four ChannelError lines. Unit tests already cover those lines. All three 5.7-source profiles have identical integration line sets between runs.

This is consistent with transport timing changing the error observed during disconnect. No runtime source files changed between these PRs. The overall coverage source digests differ because lab sources changed. Runtime file content and mapped line sets were checked separately before comparing line numbers. Keep the unit checks and reconnect scenarios; do not require one particular incidental socket error from every CI run.

## Build cost

| Job | PR #40 seconds | PR #41 seconds |
|---|---:|---:|
| Shared lab build | 51 | 114 |
| Release build | 131 | 378 |
| Coverage build | 19 | 229 |
| Unit tests | 118 | 366 |
| Periphery | 182 | 413 |

The lab Actions cache reported a miss. The release build imported its base-branch GHCR cache. SQLite and Rust dependency layers were cached. The release log shows layer download/extraction, application compilation, package work, and an 81-second cache export. It does not show a new SQLite or zstd compilation. The subsequent runtime export reused the layers built in the same job.

Longer build jobs reduce the elapsed-time benefit from faster tests. Do not describe this run as a uniformly warm-cache comparison. Investigate Actions cache scope separately from Docker native-library reuse.

## Next step

Keep the query grouping. Rebalance DDL and bootstrap into two contiguous shards per profile/variant, subject to CI validation. The PR #41 case-time model predicts roughly 137–184 seconds per DDL shard and 240–257 seconds per bootstrap shard before extra CI job overhead. Preserve all case IDs, dependency closure, assertions, and intermediate/binlog checks.

That proposal removes 12 release shards and 12 coverage copies without removing cases. Keep the existing sample and smoke selections during this next comparison. Select the explicit PR subset after the suite is organized and measured. Do not remove bootstrap or DML fixtures because their Swift line sets overlap.
