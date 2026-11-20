# tachyon - Test Suite

The Zig test suite lives under `tests/` and is aggregated by `tests/main.zig`.
Library sources contain no test blocks; new coverage belongs in the category
folders described here.

The published Zig package is runtime-only and does not include `tests/`. Run the
suite from a full repository checkout; a fetched package ships `build.zig`,
`build.zig.zon`, `src/`, `LICENSE`, and `README.md` only.

## Layout

```text
tests/
  main.zig
  support.zig
  module-test/
    module_test.zig
  error-test/
    error_test.zig
  frame-test/
    frame_test.zig
  utf8-test/
    utf8_test.zig
  fragment-test/
    fragments_test.zig
    collector_read_test.zig
    collector_policy_test.zig
  connection-test/
    connection_core_test.zig
    connection_control_test.zig
    connection_close_test.zig
    connection_limits_test.zig
    connection_read_test.zig
    connection_write_test.zig
  split-test/
    split_core_test.zig
    split_read_test.zig
    split_collector_test.zig
  handshake-test/
    handshake_request_test.zig
    handshake_head_test.zig
    handshake_response_test.zig
    handshake_client_test.zig
  upgrade-test/
    upgrade_test.zig
```

Category folders use the `<area>-test/` naming pattern, and test files use
`<concern>_test.zig`. The folders follow the protocol layers:

| Folder | Coverage |
| --- | --- |
| `module-test` | Dependency boundary and public module re-exports. |
| `error-test` | Error taxonomy, mappings, close-code policy, and classification helpers. |
| `frame-test` | Frame facade, close codes, masking, and write paths. |
| `utf8-test` | Incremental UTF-8 validation and reader adaptation. |
| `fragment-test` | Fragment accumulator, collector reads, and collector policy. |
| `connection-test` | Connection core, control replies, close handling, limits, reads, and writes. |
| `split-test` | Split core, reads, and `FragmentCollectorRead`. |
| `handshake-test` | Request, head, response, and client handshake behavior. |
| `upgrade-test` | Server upgrade call order, including validation and async behavior. |

`tests/main.zig` imports every category test file in one `test` block. It is the
root module for both the Debug and ReleaseSafe test steps. `tests/support.zig`
holds shared fixtures and test-only readers and writers; category files that
need them import the support file instead of duplicating fixtures.

## Naming

Name test blocks `<Area>: <behavior>`, for example
`Frame: encodes a masked extended-length header`. Keep one behavior per block,
assert typed errors for failure paths, and follow the boundary and malformed
input coverage in [AGENTS.md](../AGENTS.md#testing-guidelines).

## Running

```sh
zig build test              # Debug and ReleaseSafe suites over tests/main.zig
zig build test --summary all
zig build check             # type-check the library and tests
zig fmt --check .           # formatting gate
```

`zig build test` runs the aggregate twice, once with Debug safety and once with
ReleaseSafe, so overflow and bounds behavior is exercised in both modes.

## Adding Coverage

1. Choose the matching `tests/<area>-test/` folder, or add a new category folder
   when the protocol area does not have one.
2. Add focused tests to an existing `<concern>_test.zig` file or create a new
   file for a distinct concern.
3. Import a new file from `tests/main.zig`.
4. Reuse `tests/support.zig` for fixtures shared by more than one category.
5. Run `zig build test` and `zig fmt --check .` before review.

## Future Integration Suites

Autobahn, fuzz, and loopback suites belong under `tests/` as new category
folders. None is implemented yet. This tree currently provides unit coverage
only; do not claim Autobahn, fuzz, or loopback compliance until those suites
exist and pass.
