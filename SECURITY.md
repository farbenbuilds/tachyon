# Security Policy

## Reporting a Vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting for
[farbenbuilds/tachyon](https://github.com/farbenbuilds/tachyon/security/advisories/new).
If unavailable, contact the maintainer through GitHub and state that the report
is security-sensitive.

Include:

- a description of the issue,
- the affected version or commit,
- reproduction steps or a minimal frame sequence,
- actual or potential impact,
- any suggested mitigation.

## Scope

Security-relevant areas include:

- Framing, masking, limits, close handling, and UTF-8 validation: header and
  extended-length parsing, masking direction and keys, close codes and reasons,
  message-size accounting, and incremental text validation.
- Connection and transport policy: client mask-key sources, fragmentation,
  streaming, backpressure, slow consumers, native stream lifetimes, and
  read/write cancellation.
- Handshake and extensions: client handshake, server upgrade, origin handling,
  extension negotiation, permessage-deflate bounds, and decompression bombs.
- Application and safety: pub/sub fanout limits, unbounded lengths or loops,
  and memory-safety failures in Zig safety modes.

zslay owns header coding, length handling, masking, close validation, fragment
ordering, limits, and the bounded connection state machine. Report a zslay-only
defect to [farbenbuilds/zslay](https://github.com/farbenbuilds/zslay/security/advisories/new);
report tachyon policy, buffering, UTF-8, handshake, upgrade, compression, or
stream adapter defects here.

## Supported Versions

Security fixes target the latest tagged release; `main` and pre-release branches
are development branches and receive fixes at the maintainer's discretion.

## Disclosure Policy

The maintainer will acknowledge a report, confirm the affected range, prepare a
fix, and coordinate disclosure. Please allow reasonable time for a fix before
public disclosure. Credit is given to reporters who request it.

## Security Expectations for Contributors

- Treat all peer-controlled lengths and opcodes as untrusted.
- Keep the frame and connection hot paths free of allocation.
- Seed client mask keys from a uniform, secret source in production. A
  deterministic seed is only for tests and reproducible harnesses. The
  connection never reads ambient randomness, so the caller owns seed sourcing.
- Do not log payload bytes.
- Add a regression test with every security fix.
- Do not silence a safety check or weaken a bound to make a test pass.
