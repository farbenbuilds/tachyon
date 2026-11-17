# Security Policy

## Reporting a Vulnerability

Do not open a public issue for a security vulnerability.

Use GitHub's private vulnerability reporting for
[farbenbuilds/tachyon](https://github.com/farbenbuilds/tachyon/security/advisories/new).
If private reporting is unavailable, contact the maintainer through the GitHub
profile for `farbenbuilds` and state that the report is security-sensitive.

Include:

- a description of the issue,
- the affected version or commit,
- reproduction steps or a minimal frame sequence,
- actual or potential impact,
- any suggested mitigation.

## Scope

Security-relevant areas include:

- frame header and extended-length parsing,
- masking direction and key handling,
- fragmentation and message-size accounting,
- close-code and UTF-8 reason validation,
- HTTP upgrade and client handshake validation,
- denial of service through unbounded lengths, loops, or buffering,
- memory-safety failures in Zig safety modes.

zslay owns the frame codec primitives. A defect that reproduces in zslay alone
should also be reported to
[farbenbuilds/zslay](https://github.com/farbenbuilds/zslay/security/advisories/new).
A defect in tachyon's connection policy, handshake, fragmentation, or stream
adapter belongs here.

## Supported Versions

Security fixes target the latest released minor version. Pre-release and
unreleased branches receive fixes at the maintainer's discretion. The current
tree is not a released version and should not be deployed as a production
server.

## Disclosure Policy

The maintainer will acknowledge a report, confirm the affected range, prepare a
fix, and coordinate disclosure. Please allow reasonable time for a fix before
public disclosure. Credit is given to reporters who request it.

## Security Expectations for Contributors

- Treat all peer-controlled lengths and opcodes as untrusted.
- Keep the frame and connection hot paths free of allocation.
- Do not log payload bytes.
- Add a regression test with every security fix.
- Do not silence a safety check or weaken a bound to make a test pass.
