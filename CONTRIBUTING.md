# Contributing

Use FVM for all Dart/Flutter commands and the repository-local Melos dependency.
Run analysis, tests and the format check before submitting changes.

## Conventional Commits

Use meaningful, package-scoped Conventional Commits:

```text
feat(lti): support deep linking responses
fix(lti_shelf): preserve session cookies on launch
docs: explain platform registration
feat(lti)!: replace the transaction storage contract
```

Allowed types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`,
`ci`, `chore`, `revert`. Use `!` or a `BREAKING CHANGE:` footer for breaking changes.
Keep a blank line between the subject and body. Do not include access tokens,
private keys or identifiable launch payloads in commits or test fixtures.

Enable the local commit-message check in each checkout:

```sh
git config core.hooksPath .githooks
```

CI checks PR commits (excluding merge commits) using the same Dart validator.
When squashing, preserve a Conventional Commit subject and any breaking-change
footer. Melos derives changes for each package from Git history and package tags.

## Releases

Versions currently use `0.1.0-dev.1`. Once changes are committed, start the
interactive release workflow:

```sh
fvm dart run melos version --prerelease --preid=dev
```

Review the proposed changes at the confirmation prompt before accepting them.
To inspect a release without changing files, decline that prompt. Melos 8 does
not provide a `version --dry-run` option.

Melos creates release commits with `chore(release): publish packages`, updates
dependent constraints and creates package tags. Versioning is based on
Conventional Commits by default. Publishing and pushing tags are separate,
intentional release actions. Do not graduate these packages to stable until the
documented compatibility requirements are met.

The first release establishes package tags; subsequent releases compare against
them. No release tags or commits are generated automatically by bootstrap or CI.

## Public API documentation

Every public API used by a package consumer needs meaningful English Dartdocs:
classes, constructors, methods, properties, typedefs and enum values. Explain
what the consumer needs to know: parameter constraints and defaults, nullable
values, return values, exceptions, ownership/lifetime, side effects and trust
boundaries. Do not merely repeat the declaration's name. Inherited API comments
may document overrides when their contract is unchanged. Add short examples for
workflows such as launches, selections and service writes.

`public_member_api_docs` and `comment_references` run in normal analysis and CI.
Generate both packages' API sites and validate links before submitting changes:

```sh
fvm dart run melos run docs
```

Open `build/api/lti/index.html` or `build/api/lti_shelf/index.html`. Output stays
ignored. Both packages treat unresolved documentation references and broken links
as generation errors. Keep package README links usable in standalone pub.dev
pages; repository-relative links outside the package do not resolve there.
