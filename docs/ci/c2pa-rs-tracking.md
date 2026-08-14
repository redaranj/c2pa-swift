# c2pa-rs tracking branches

Two robot-owned branches continuously answer whether `main` still works against
upstream c2pa-rs. Both are force-pushed and must never be used as a base for
work.

| Branch | Follows | Meaning when red |
| -- | -- | -- |
| `track/c2pa-rs-stable` | latest published release | Urgent. That version is out and `main` cannot move to it. |
| `track/c2pa-rs-rc` | the in-flight breaking train | Informational early warning, with the rest of the bake to react. |

Each branch is always `origin/main` plus one pin-bump commit. Nothing
originates on a tracking branch.

## Fixing a red tracker

Land an ordinary PR against `main`. The tracker hard-resets from `main` on
every sync, so the next run picks the fix up, goes green, and closes its own
issue.

## Upstream's release model

See [c2pa-rs docs/release-process.md](https://github.com/contentauth/c2pa-rs/blob/main/docs/release-process.md).
Additive `0.x.y` releases ship continuously from `stable`; breaking changes
batch onto a train cut on the second Monday of odd-numbered months, which bakes
for at least three business days and publishes `-rc.N` prerelease binaries.
Trains are skipped when nothing breaking is queued, so `track/c2pa-rs-rc`
no-ops most of the time.

## Validating on a fork

Enable Actions and Issues on the fork first; both are off by default.

| Step | Dispatch | Expected |
| -- | -- | -- |
| 1 | stable, `version=v0.90.0`, `dry_run=true` | Resolves, 7/7 assets preflight, nothing pushed |
| 2 | stable, no version | Exits via the idempotence guard (already on this pin) |
| 3 | stable, `version=v0.89.3` | Green path: branch, test, matrix, promotion PR |
| 4 | rc, `version=v0.90.0-rc.3` | Matches the outcome recorded in `c2pa-rs-0.90-rc-preflight` |
| 5 | stable, `version=v0.84.1` | Red path: branch pushed anyway, issue filed |
| 6 | push any commit to fork `main` | Tracker re-syncs and auto-closes the issue |

GitHub disables `schedule` on forks by default and auto-disables it after 60
days of repository inactivity, so the scheduled path is exercised only after
the workflows land upstream.

Both callers must live on the fork's default branch before anything runs. That
applies to all three triggers, not just the cron: `schedule` only ever fires
from the default branch, and `workflow_dispatch` will not even appear in the
Actions tab until the file is there.

### Concurrency

Runs queue rather than cancel each other (`cancel-in-progress: false`). A full
cycle is sync, then the matrix, then the promotion PR, and sync force-pushes
the branch partway through. Cancelling mid-cycle leaves the branch pushed and
marked as synced while the PR still names the previous version; because the
marker is what the idempotence guard reads, every later run then skips and the
PR stays wrong until upstream ships a new version. A superseded run costs
almost nothing anyway: the guard no-ops it in about 20 seconds.

A cycle with real work takes 45 to 70 minutes, most of it the macOS build and
the simulator matrix. Polling faster than that just means one run is always
queued behind another.

### Temporary test cadence

The cron in both callers is currently `*/30 * * * *` (every 30 minutes) for
fork validation. **Revert both to `0 */6 * * *` before proposing this
upstream.** Six-hourly is the intended cadence: upstream publishes additive
releases on roughly a one-day bake and cuts a breaking train every two months,
so a 30-minute poll buys nothing in production and just burns Actions minutes.

## Adding or removing an Apple target

`.github/scripts/check-c2pa-assets.sh` holds the list of required per-target
archives. It must stay in lockstep with the `download_and_extract` calls in the
C2PAC framework build phase in `Library/Library.xcodeproj/project.pbxproj`.

## Local test suite

The helper scripts under `.github/scripts/` are unit-tested offline against
JSON fixtures, with no network and no Xcode required. Run them with
`make test-ci-scripts` (also run as part of `make test`). Tests live in
`tests/ci/run-tests.sh`, fixtures in `tests/ci/fixtures/`.

Fixture design rule: a trap planted in a fixture must be able to win if the
guard against it regresses. A decoy whose version sits below the correct
answer is inert -- the suite will pass even with the guard deleted.
`releases.json` is the rich integration fixture; `stable-with-rc.json`,
`stable-with-other-crates.json` and `stable-with-draft.json` isolate one guard
each so a failure names which guard broke.
