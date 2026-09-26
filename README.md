# lti.dart

Dart libraries for building **LTI 1.3 tools**. This repository contains the
protocol library and HTTP adapters, not a learning application or an LMS.

| Package | Purpose |
| --- | --- |
| `lti` | Framework-independent registration, OIDC login and resource launch verification |
| `lti_shelf` | Shelf routes and browser binding for resource launches |

## Status

**Early development — not yet a complete or certified LTI 1.3 implementation.**
The first milestone supports manually registered platforms, OIDC login and
RS256-verified resource launches, including anonymous launches. Deep Linking,
AGS, NRPS, outgoing tool signatures and dynamic registration are not implemented.
ByCS interoperability has not yet been tested against a live registration.

See [architecture and security contracts](docs/architecture.md) and the
[implementation matrix](docs/implementation.md) for the remaining scope.

## Development

The repository pins Flutter 3.47.0 via FVM (Dart 3.13.0). The packages themselves
are pure Dart. Melos 8 is configured in the root `pubspec.yaml`, using a Dart pub
workspace and one checked-in lockfile.

```sh
fvm install
fvm dart pub get
fvm dart run melos bootstrap
fvm dart run melos run analyze
fvm dart run melos run test --no-select
fvm dart run melos run format:check
```

No code generation is needed for the current implementation. Protocol parsing
is explicit so validation and trust boundaries remain visible. Add generators
when their benefit outweighs maintaining another build step.

See [CONTRIBUTING.md](CONTRIBUTING.md) for Conventional Commits and versioning.

## Integration

See the [Shelf integration example](packages/lti_shelf/example/server.dart).
It illustrates configuration and a verified launch callback; application
sessions, authorization and the learning interface belong to the consuming tool.

Before running an integration, obtain the platform's exact issuer, client ID,
deployment IDs, authorization endpoint and public JWKS URL. Register the tool's
login URL and exact redirect URL in the platform. Configure allowed target URLs
explicitly; do not infer trust from unsigned login parameters.

The current adapter uses a `Secure`, `HttpOnly`, `SameSite=None`, host-only cookie
per login. If the browser blocks third-party cookies, use a top-level launch.
Cookie-free iframe launches are a separate planned feature; disabling browser
binding is not a supported workaround.

For development, run behind an HTTPS reverse proxy. The memory transaction store
is intended for tests and single-isolate development. Production needs shared,
atomic transaction storage, HTTPS, request timeouts and login rate limiting.

## Standards

- [LTI 1.3 Core](https://www.imsglobal.org/spec/lti/v1p3/)
- [1EdTech Security Framework](https://www.imsglobal.org/spec/security/v1p0/)
- [Deep Linking 2.0](https://www.imsglobal.org/spec/lti-dl/v2p0)
- [Assignment and Grade Services 2.0](https://www.imsglobal.org/spec/lti-ags/v2p0)
- [Names and Role Provisioning Services 2.0](https://www.imsglobal.org/spec/lti-nrps/v2p0)
