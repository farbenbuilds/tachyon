# Git Commit Message Convention

Adapted from [Angular's commit convention](https://github.com/conventional-changelog/conventional-changelog/tree/master/packages/conventional-changelog-angular).

## Examples

Feature under the `connection` scope:

```text
feat(connection): add automatic pong replies
```

Bug fix under the `frame` scope with an issue link:

```text
fix(frame): reject fragmented control frames

Closes #28
```

Performance change with a breaking note:

```text
perf(connection): remove hidden allocation from the write path

BREAKING CHANGE: Callers now provide the write scratch buffer explicitly.
```

Revert:

```text
revert: feat(frame): add experimental masking path

This reverts commit 667ecc1654a317a13331b17617d973392f415f02.
```

## Format

A commit message has a header, an optional body, and an optional footer.

```text
<type>(<scope>): <subject>
<BLANK LINE>
<body>
<BLANK LINE>
<footer>
```

The header is mandatory. The scope is optional.

## Type

`feat`, `fix`, and `perf` appear in the changelog. Other prefixes are allowed
for non-changelog work: `build`, `ci`, `docs`, `style`, `refactor`, and `test`.
A `BREAKING CHANGE` footer always appears in the changelog.

## Scope

Use the area being changed. Examples for tachyon: `frame`, `close`, `mask`,
`connection`, `fragment`, `handshake`, `upgrade`, `split`, `flake`, `docs`,
`agents`, `tests`.

## Subject

- Use the imperative present tense: "change", not "changed" or "changes".
- Do not capitalize the first letter.
- Do not end with a period.
- Keep the subject concise.

## Body

Use the imperative present tense. Explain the motivation and contrast with the
previous behavior. Wrap lines at a readable width.

## Footer

Reference issues with `Closes #123`. Start breaking changes with
`BREAKING CHANGE:` followed by the migration requirement.

See [CONTRIBUTE.md](../CONTRIBUTE.md) for the full contribution workflow.
