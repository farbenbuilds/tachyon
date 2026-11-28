# tachyon - CI/CD Pipeline

Contract for the GitHub Actions workflows. The lint, test, Autobahn, and
benchmark workflows are implemented in `.github/workflows/lint.yml`,
`.github/workflows/test.yml`, `.github/workflows/autobahn.yml`, and
`.github/workflows/bench.yml`. Releases are manual and tag-driven; there is no
publish workflow.

## Workflows

| Workflow | Trigger | Status and purpose |
| --- | --- | --- |
| `.github/workflows/lint.yml` | Pull request into `main` changing `.zig`, `.zon`, or `build.zig` files | Implemented. `zig fmt --check .` with Zig 0.17.1. |
| `.github/workflows/test.yml` | Pull request into `main` and push to `main` changing Zig or Zon files, `build.zig`, or workflows | Implemented. Native `zig build test --summary all` and `zig build check` plus an eight-target compile-only `cross-check` matrix. |
| `.github/workflows/autobahn.yml` | Pull request into `main` and push to `main` changing Zig or Zon files, `build.zig`, or workflows | Implemented. Pinned Autobahn testsuite gate over the `tests/autobahn-test/` echo fixture, split into independent case groups with per-group report artifacts. |
| `.github/workflows/bench.yml` | Manual dispatch and weekly schedule | Implemented. Builds the examples and benchmark tools, fetches and builds the comparison servers, runs the Node benchmark runner, and publishes the generated `benches/README.md` results and charts. |

## Lint Pipeline

Implemented in `.github/workflows/lint.yml` for pull requests into `main` that
change a `.zig`, `.zon`, or `build.zig` file. It requests `contents: read` and
runs `zig fmt --check .` in the `Linting` environment with `actions/checkout` v7
and `mlugg/setup-zig` v2; it does not use Nix.

## Test Pipeline

Implemented in `.github/workflows/test.yml` for pull requests into `main` and
pushes to `main` that change a `.zig` or `.zon` file, `build.zig`, or a workflow
file. It requests `contents: read`, cancels superseded runs, and defines two
jobs on `ubuntu-latest` in the `Testing` environment.

### Native runtime job

The `test` job, named `Run Zig Tests`, is the 15-minute runtime gate. It checks
out with `actions/checkout` v7, installs Zig 0.17.1 with `mlugg/setup-zig` v2,
runs `zig build test --summary all` under Debug and ReleaseSafe, and runs
`zig build check` to type-check the library and both test roots.

The job does not use Nix. The flake still exposes `format`, `test-default`, and
`test-musl` checks, plus `packages.default`: `format` checks `flake.nix` with
alejandra, `test-default` runs a native `zig build test`, `test-musl` runs a musl
`zig build test` on Linux, and `packages.default` builds `libtachyon.a` with
`ReleaseSafe`. The check derivations seed Zig's cache from the generated
`build.zig.zon.nix` because the sandbox has no network access.

### Cross-target compile check

The `cross-check` job is a compile-only matrix with a 20-minute timeout and
`fail-fast: false`. It runs `zig build check -Dtarget=<target>` for x86_64 and
aarch64 Linux (gnu and musl), x86 Linux musl, x86_64 and aarch64 macOS, and
x86_64 Windows. A foreign binary cannot run on the Linux runner, so these jobs
are not runtime evidence; the native `test` job remains the runtime gate.
Compilation covers the library and both test roots, including the test-only
32-bit fix in `tests/connection-test/connection_limits_test.zig`, so target
portability failures surface before merge. No runtime coverage is claimed for
macOS, Windows, or non-x86_64 Linux targets in CI.

## Autobahn Pipeline

Implemented in `.github/workflows/autobahn.yml`. Runs on pull requests into
`main` and pushes to `main` that change a `.zig` or `.zon` file, `build.zig`, or
a workflow file. The workflow requests `contents: read`, cancels superseded runs,
and runs a `fail-fast: false` matrix on `ubuntu-24.04` in the `Testing`
environment. Each entry gets a fresh runner and container, a 30-minute job
timeout, and a 1500-second suite timeout.

| Group | Cases |
| --- | --- |
| `core` | `1.* 2.* 3.* 4.* 5.* 6.* 7.* 9.* 10.*` |
| `deflate-12-1-2` | `12.1.* 12.2.*` |
| `deflate-12-3-4` | `12.3.* 12.4.*` |
| `deflate-12-5` | `12.5.*` |
| `deflate-13-1` | `13.1.*` |
| `deflate-13-2` | `13.2.*` |
| `deflate-13-3-4` | `13.3.* 13.4.*` |
| `deflate-13-5-7` | `13.5.* 13.6.* 13.7.*` |

1. Check out the repository with `actions/checkout` v7.
2. Install Zig 0.17.1 with `mlugg/setup-zig` v2.
3. Run `zig build autobahn-server -Doptimize=ReleaseSafe` to install
   `zig-out/bin/tachyon-autobahn`.
4. Run `farbenbuilds/autobahn-action` pinned at
   `1c4d57b3ca48e1ddf742e5ae1ab4ce5b51625b36` (`v1`) with
   `server-command: ./zig-out/bin/tachyon-autobahn`, URL
   `ws://127.0.0.1:9001`, host Docker networking, and `cases` from the matrix.
   The action waits for a complete handshake before running the suite.

The configured case set is `1.* 2.* 3.* 4.* 5.* 6.* 7.* 9.* 10.* 12.* 13.*`.
Groups 8 and 11 have no cases in the pinned testsuite, so they are not matrix
entries. Compression groups 12-13 are enabled through the fixture's negotiated
permessage-deflate composition. `fail-on: failed` fails a group on failed cases;
non-strict outcomes are reported but do not gate. Reports are written to
`autobahn-reports-<group>`, uploaded as `autobahn-report-<group>`, and appended
to the step summary. Splitting the suite keeps each container's memory from
accumulating across case groups.

The current full gate run reports 517 cases: 511 passed, 0 failed, 3 non-strict
(6.4.2-6.4.4), and 3 informational. All 216 cases in groups 12-13 passed. A
green run is evidence only for the configured case set, not a full Autobahn or
compression compliance claim.

## Path Filters

The test and Autobahn workflows run when any of these changes:

- `**/*.zig`
- `**/*.zon`
- `build.zig`
- `.github/workflows/**`

The lint workflow uses the Zig and Zon path set plus `build.zig`.
Documentation-only changes do not trigger CI. Workflow-only changes run the test
and Autobahn workflows so configuration changes are exercised before merge, and
both publish a `Testing` deployment. The benchmark workflow is manual and
scheduled only; it is not a pull-request gate.

## Dependency Updates

Dependabot watches the `github-actions` ecosystem at the repository root once a
week, on Monday at 06:00 UTC, and allows at most five open version-update pull
requests. Minor and patch updates are grouped; major updates stay separate.
Commits and pull request titles use the `ci(actions)` prefix, and Dependabot's
generated `Bump` subject is the documented lowercase exception.

Dependabot edits the existing `uses:` lines. The workflows pin each action to a
commit SHA with a trailing version comment, including the
`farbenbuilds/autobahn-action` pin at
`1c4d57b3ca48e1ddf742e5ae1ab4ce5b51625b36` (`v1`), so an update moves the SHA
and raises the comment. Only the `github-actions` ecosystem is configured; Zig
is not a Dependabot ecosystem, so `build.zig.zon` and `flake.lock` updates remain
manual.

Dependabot pull requests are ordinary pull requests and need the same review.
Their workflow runs receive a read-only `GITHUB_TOKEN` and no repository or
environment secrets. An Actions update changes only `.github/workflows/**`, so
the test and Autobahn workflows run while the lint workflow does not. A change
to `.github/dependabot.yml` matches neither filter; contributors validate it
with the `check-yaml` pre-commit hook before opening a pull request.

## Benchmark Pipeline

Implemented in `.github/workflows/bench.yml`. It runs on manual dispatch and a
weekly schedule, never on pull requests. It installs Zig, Node, and Rust with
the standard setup actions plus the Ubuntu build packages, builds
`zig build examples benches -Doptimize=ReleaseFast`, runs
`sh benches/setup-competitors.sh` (best effort) to build the C++ uWebSockets and
Rust comparison servers, and runs `node benches/run.mjs`. The runner writes the
table and per-case SVG charts into `benches/README.md`; the workflow appends
that block to the step summary and uploads the README and charts as artifacts.
Missing comparison servers are skipped, so the tachyon results still publish.
The workflow does not use Nix and does not bundle competitor sources.

## Manual Release

This process is not a workflow. It runs on the maintainer's machine and GitHub
account.

1. Confirm the intended tag, `build.zig.zon` `.version`, `flake.nix` package
   version, and the matching changelog section agree.
2. Confirm the dated release section exists and no empty `Unreleased`
   placeholder remains.
3. Run the full checks.
4. The maintainer creates and pushes an annotated `v*` tag.
5. The maintainer creates the GitHub release from the changelog notes.
6. No workflow run, artifacts, packages, checksums, or uploads are required.

## Required Permissions and Secrets

| Name | Use |
| --- | --- |
| `contents: read` | Checkout, lint, flake checks, test jobs, the Autobahn gate, and the benchmark workflow. |

The lint, test, Autobahn, and benchmark workflows request `contents: read`.
The Autobahn action uses the runner runtime token for artifact upload and needs
no repository or environment secret. A manual release uses the maintainer's
GitHub permissions, not a workflow token. No third-party registry credentials
are required.

## Versioning Rules

- Use semantic versioning.
- The tag, `build.zig.zon`, `flake.nix`, and the changelog section must agree
  before a release.
- Keep `ReleaseSafe` for local and package builds so bounds and overflow checks
  remain enabled.
- No distributed artifacts are produced by the manual release process.
- Never tag or release from a dirty tree or an unpinned zslay revision.
