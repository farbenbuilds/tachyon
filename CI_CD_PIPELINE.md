# tachyon - CI/CD Pipeline

Contract for the GitHub Actions pipelines. The lint and test workflows are
implemented in `.github/workflows/lint.yml` and `.github/workflows/test.yml`;
the release workflow is specified here and remains planned.

## Workflows

| Workflow | Trigger | Status and purpose |
| --- | --- | --- |
| `.github/workflows/lint.yml` | Pull request into `main` changing `.zig`, `.zon`, or `build.zig` files | Implemented. `zig fmt --check .` with Zig 0.17.1. |
| `.github/workflows/test.yml` | Pull request into `main` and push to `main` changing Zig or Zon files or workflows | Implemented. `zig build test --summary all` and `zig build check` with Zig 0.17.1. |
| `.github/workflows/publish.yml` | Push of a `v*` tag | Planned. Verify version and changelog, build cross-target packages, publish release assets. |

## Lint Pipeline

Implemented in `.github/workflows/lint.yml`. Runs on pull requests into `main`
that change a `.zig` file, a `.zon` file, or `build.zig`. The workflow requests
`contents: read` and defines one job, `fmt`, named `Check Zig Formatting`, on
`ubuntu-latest` in the `Linting` environment.

1. Check out the repository with `actions/checkout` v7.
2. Install Zig 0.17.1 with `mlugg/setup-zig` v2.
3. Run `zig fmt --check .`.

The lint job does not use Nix, so formatting failures surface quickly without
waiting for a full flake evaluation.

## Test Pipeline

Implemented in `.github/workflows/test.yml`. Runs on pull requests into `main`
and pushes to `main` that change a `.zig` or `.zon` file, `build.zig`, or a
workflow file. The workflow requests `contents: read`, cancels superseded runs
for the same ref, and defines one job, `test`, named `Run Zig Tests`, on
`ubuntu-latest` in the `Testing` environment. Every test run therefore records
a `Testing` deployment, alongside the `Linting` deployment from the lint job.

1. Check out the repository with `actions/checkout` v7.
2. Install Zig 0.17.1 with `mlugg/setup-zig` v2.
3. Run `zig build test --summary all`, which executes the aggregate suite under
   Debug and ReleaseSafe.
4. Run `zig build check` to type-check the library and both test roots.

The job does not use Nix, so the result does not depend on the runner's Nix
installation or on a cached flake evaluation. The flake still exposes the
`format`, `test-default`, and `test-musl` checks for hermetic offline runs,
plus `packages.default`:

- `format` checks `flake.nix` with alejandra,
- `test-default` runs a native `zig build test`,
- `test-musl` runs a musl `zig build test` on Linux,
- `packages.default` builds `libtachyon.a` with `ReleaseSafe`.

`zig build test` runs the suite in Debug and ReleaseSafe. The Nix check
derivations seed Zig's package cache from the generated `build.zig.zon.nix`
because the build sandbox has no network access.

## Path Filters

The implemented test workflow runs when any of these changes:

- `**/*.zig`
- `**/*.zon`
- `build.zig`
- `.github/workflows/**`

The lint workflow uses the Zig and Zon path set plus `build.zig`.
Documentation-only changes do not trigger either job. Workflow-only changes run
the test workflow so CI configuration changes are exercised before merge and
publish a `Testing` deployment.

## Dependency Updates

The GitHub Actions used by the workflows are kept current by Dependabot through
`.github/dependabot.yml`. The configuration watches the `github-actions`
ecosystem at the repository root once a week, on Monday at 06:00 UTC, and
allows at most five open version-update pull requests. Minor and patch updates
are grouped into one pull request; major updates stay separate so a breaking
change gets its own review. Commits and pull request titles use the
`ci(actions)` prefix. Dependabot's generated subject begins with `Bump`, which
is the documented exception to the lowercase-subject rule.

Dependabot edits the existing `uses:` lines. Both workflows pin each action to
a commit SHA with a trailing version comment, so an update moves the SHA and
raises the comment, and the immutable-revision rule for actions in the `release`
agent scope still holds.
Only the `github-actions` ecosystem is configured. Zig is not a Dependabot
ecosystem, so `build.zig.zon` and `flake.lock` updates remain manual.

Dependabot pull requests are ordinary pull requests and need the same review.
Their workflow runs receive a read-only `GITHUB_TOKEN` and no repository or
environment secrets. An Actions update changes only `.github/workflows/**`, so
the `test` job runs through its path filter and the `lint` job does not. A
change to `.github/dependabot.yml` matches neither filter; contributors validate
it with the `check-yaml` pre-commit hook listed in `CONTRIBUTE.md` before
opening a pull request.

## Release Pipeline

Planned. Releases are tag-driven, not push-to-main-driven.

### Verify

1. Derive the version from the tag. `v0.1.0` maps to `0.1.0`.
2. Fail when the tag, `build.zig.zon` version, and matching `CHANGELOG.md`
   section disagree.
3. Extract the matching changelog section as release notes.

### Build

1. Check out the repository and install Nix.
2. Build the default package and the target packages listed in `flake.nix` with
   `ReleaseSafe`:
   - Linux x86_64 and aarch64, glibc and musl,
   - macOS x86_64 and aarch64,
   - Windows x86_64.
3. Package Linux and macOS artifacts as `.tar.bz2`, `.tar.gz`, and `.tar.xz`
   using tools from the Nix shell. Package Windows artifacts as `.zip`.
4. Upload the archives as workflow artifacts.

### Release

1. Download the build artifacts and release notes.
2. Create or update the GitHub release for the tag.
3. Upload the archives.

## Required Permissions and Secrets

| Name | Use |
| --- | --- |
| `GITHUB_TOKEN` | Release creation and asset upload; provided by GitHub. |
| `contents: read` | Checkout, lint, flake checks, and test jobs. |
| `contents: write` | Release job only. |

The lint and test workflows request `contents: read`. The `contents: write`
entry applies to the planned release workflow. No third-party registry
credentials are required.

## Versioning Rules

- Use semantic versioning.
- The tag, `build.zig.zon`, and changelog section must agree before a release.
- Keep `ReleaseSafe` for distributed artifacts so bounds and overflow checks
  remain enabled.
- Never publish an artifact built from a dirty tree or an unpinned zslay
  revision.
