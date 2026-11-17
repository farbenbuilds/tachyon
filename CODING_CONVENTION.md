# tachyon - Coding Conventions

These conventions adapt the Linux kernel style to Zig 0.17.1 while preserving
tachyon's zero-allocation, caller-owned memory model. They apply to Zig source,
build files, tests, benchmarks, examples, and documentation. Every pull request
must satisfy them.

For architecture see [CODEBASE.md](CODEBASE.md); for setup and release process
see [CONTRIBUTE.md](CONTRIBUTE.md).

## 1. Formatting and Language Level

- Require Zig 0.17.1. The Nix flake and `build.zig.zon` pin it.
- Follow `zig fmt`: four-space indentation and standard brace placement.
- Keep lines at 120 characters or fewer.
- Use `snake_case` for files, functions, and variables.
- Use `PascalCase` for types, type-level constants, and error names.
- Use `snake_case` for `pub` functions as well as private functions.
- Do not use emojis in source, docs, branches, commits, or reviews.
- Use `@backingInt` and `@fromBackingInt` for integer-backed enums in Zig 0.17.
  Do not use the removed `@intFromEnum` and `@enumFromInt` spellings.
- Prefer `@splat` for array initialization instead of repetition expressions.

## 2. Control Flow

- Handle invalid input first and return early. Keep the happy path unindented.
- Do not nest control flow more than three levels inside a function. Extract a
  named helper instead.
- Use `switch` for multi-way branching. Do not build long `if`/`else if`
  ladders.
- Parser and connection loops must be iterative. Recursion is prohibited in
  protocol paths.
- Every loop has a fixed upper bound or a written reason why the protocol makes
  termination the caller's responsibility.
- Use `defer` and `errdefer` for cleanup. Do not emulate `goto error_out`.

## 3. Functional Core and Explicit State

- Parsing, validation, encoding, and transitions are pure functions over their
  inputs. Identical input produces identical output.
- A function may mutate caller-owned state only when that mutation is its
  documented purpose.
- No object-oriented constructs: no hidden receivers, inheritance, vtables, or
  behavior bound to global state.
- No file-scope mutable variables. A hardware or OS singleton requires a written
  justification and synchronized access.
- Prefer returning a value over an out-parameter unless a caller-owned buffer is
  required for zero allocation.
- No silent fallbacks. Invalid wire input returns a typed error.

## 4. Memory and Allocations

- The frame and connection fast paths do not allocate.
- Payloads are caller-owned slices. tachyon does not copy or free them unless a
  documented operation explicitly does so.
- Tests and examples may use an allocator, but the allocator must not leak into
  the public core.
- Pass large inputs by constant pointer or slice. Do not copy whole frames or
  message buffers onto the stack without a bound.
- Cap every peer-controlled length before indexing or reserving space.
- Use `comptime` assertions to prove header sizes, key sizes, and threshold
  relationships.

## 5. Types and Naming

- Define public types at file scope with explicit names.
- Extract repeated or anonymous compound types into named aliases. A reader must
  not need `@typeInfo` to understand a public contract.
- Use `_len` for byte counts and `_sent` for stream progress.
- Name booleans for the state they represent: `fin`, `closed`, `masked`.
- Use `?T` for optional wire values such as a masking key.
- Do not alias primitives or plain slices without a protocol reason. `Payload`
  is a slice alias because the ownership contract is the point.
- Do not use `anytype` in public or module-boundary APIs when the accepted types
  are known. Use `anytype` only for genuinely polymorphic entry points with a
  documented contract.
- Do not use `@TypeOf` or `@typeInfo` to derive an unstated public type.

## 6. Error Handling

- Use explicit Zig error sets. Public functions state their error type.
- Do not swallow errors with `catch {}` unless the operation is explicitly
  best-effort and the comment states why ignoring it is safe.
- `catch unreachable` requires a written proof that the branch cannot occur.
- Do not weaken or delete an assertion, bound, or test to make a change pass.
- Map zslay protocol errors at the tachyon boundary when the fastwebsockets
  contract needs a different category. Do not collapse distinct failures into
  `error.InvalidValue`.
- Errors carry no hidden allocation and no formatted message. Callers format
  diagnostics.

## 7. Public API Rules

- Mirror fastwebsockets names and behavior unless Zig requires a different
  spelling. Document deliberate differences in `CODEBASE.md`.
- Keep setters explicit: `set_auto_close`, `set_auto_pong`,
  `set_auto_apply_mask`, `set_max_message_size`, `set_writev`, and
  `set_writev_threshold`.
- Defaults must match fastwebsockets: automatic close, automatic pong, automatic
  mask application, and a 64 MiB maximum message size unless a later decision
  records a different bound.
- Close-code and masking APIs are aliases or delegates to zslay. Do not define a
  second `CloseCode` enum, allowed-range table, close-payload validator, or XOR
  loop.
- Optional extensions stay at the edge. Backpressure, streaming, native stream,
  UTF-8, deflate, and pub/sub must not add allocation, I/O, or negotiation state
  to the frame core.
- Bound decompressed output by the configured message limit before delivery, and
  never compress control frames.
- Validate text incrementally across frames and fail closed on invalid UTF-8;
  never substitute replacement characters.
- A client masks outbound frames; a server unmasks inbound frames. Role is part
  of the connection state, not a hidden global.
- A close write is terminal for data writes. Repeated close writes are still
  serialized, matching fastwebsockets; other writes after close return
  `error.ConnectionClosed`.
- Reading after close may deliver the peer close frame, but must not deliver
  application data.

## 8. Comments and Documentation

- Comments explain why, not what. Point to an RFC section, a byte value, a
  capacity, an ownership rule, or a deliberate divergence.
- Do not add `TODO`, `FIXME`, `XXX`, or `HACK` markers.
- Use `//` comments. `///` doc comments are allowed only when the public API
  needs a contract that the type and name cannot express.
- Do not use `std.debug.print` outside test blocks. Library diagnostics use
  `std.log.scoped(.tachyon)` if logging is ever required.
- Delete dead code, unused imports, and commented-out blocks in the same change.
- Do not include generated output, payload dumps, or secrets in documentation.

## 9. Testing

- Put unit tests in `src/test.zig`, named `<Area>: <behavior>`.
- Tests must exercise both success and failure paths for changed protocol code.
- Cover the length boundaries in [AGENTS.md](AGENTS.md#testing-guidelines).
- Prefer fixed byte arrays and explicit expected values over generated data.
- Do not let a test depend on wall-clock time, network access, or host locale.
- Run `zig build test` and `zig fmt --check .` before review.

## 10. Verification

Environment and documentation changes require:

```sh
nix flake check
pre-commit run --all-files
```

Code changes also require:

```sh
zig fmt --check .
zig build check
zig build test
```

Reviewers verify that the change does not weaken these gates, remove coverage,
or hide a failure.

## 11. Example

```zig
const std = @import("std");
const zslay = @import("zslay");

// Returns the wire length after proving the payload fits the frame budget.
pub fn checked_payload_len(payload_len: usize, max_len: usize) !usize {
    if (payload_len > max_len) return error.FrameTooLarge;

    return payload_len;
}

// Encodes a masked text header from caller-owned storage.
// The length marker is part of the RFC 6455 header, not the raw payload length.
pub fn encode_text_header(
    out: []u8,
    payload_len: u64,
    key: zslay.MaskingKey,
) !usize {
    const header = zslay.FrameHeader{
        .opcode = @backingInt(zslay.Opcode.text),
        .rsv3 = false,
        .rsv2 = false,
        .rsv1 = false,
        .fin = true,
        .payload_len = zslay.frame.length_marker(payload_len),
        .mask = true,
    };

    return zslay.encode_header(out, header, payload_len, key);
}
```

The example is illustrative; production code uses the named aliases and bounds
established in `src/frame.zig`.
