# tachyon - CI/CD Pipeline

Contract for the GitHub Actions pipelines. This change intentionally does not
add workflow files. The sections below define the formatting, test, and release
pipelines.

## Planned Workflows

| Workflow | Trigger | Purpose |
| --- | --- | --- |
| `.github/workflows/lint.yml` | Pull request into `main` touching Zig or build files | `zig fmt --check .` with Zig 0.17.1. |
| `.github/workflows/test.yml` | Pull request into `main` and push to `main` | Formatting plus `nix flake check` for native and musl test derivations. |
| `.github/workflows/publish.yml` | Push of a `v*` tag | Verify version and changelog, build cross-target packages, publish release assets. |

## Lint Pipeline

Runs on pull requests that modify `.zig`, `.zon`, or `build.zig` files.

1. Check out the repository.
2. Install Zig 0.17.1 with `mlugg/setup-zig`.
3. Run `zig fmt --check .`.

The lint job does not use Nix, so formatting failures surface quickly without
waiting for a full flake evaluation.

## Test Pipeline

Runs on pull requests into `main` and pushes to `main`.

1. Check out the repository.
2. Install Nix with flakes enabled.
3. Cache Nix evaluation keyed on `flake.lock`.
4. Run `nix develop -c zig fmt --check .`.
5. Run `nix flake check --print-build-logs`.

The test flake performs:

- a formatting check in a minimal derivation,
- a native `zig build test` check,
- a musl `zig build test` check on Linux,
- native and cross-target package builds when requested.

`zig build test` runs the suite in Debug and ReleaseSafe. The Nix check
derivations seed Zig's package cache from the generated `build.zig.zon.nix`
because the build sandbox has no network access.

## Path Filters

The test workflow should run when any of these change:

- `**/*.zig`
- `**/*.zon`
- `build.zig`
- `flake.nix`
- `flake.lock`
- `.github/workflows/**`
- `src/**`
- root project documentation that changes build or verification instructions

## Release Pipeline

Releases are tag-driven, not push-to-main-driven.

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
| `contents: read` | Checkout, flake checks, and test jobs. |
| `contents: write` | Release job only. |

No third-party registry credentials are required.

## Versioning Rules

- Use semantic versioning.
- The tag, `build.zig.zon`, and changelog section must agree before a release.
- Keep `ReleaseSafe` for distributed artifacts so bounds and overflow checks
  remain enabled.
- Never publish an artifact built from a dirty tree or an unpinned zslay
  revision.
