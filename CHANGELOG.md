# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2026-09-27

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`lti` - `v0.1.0`](#lti---v010)
 - [`lti_shelf` - `v0.1.0`](#lti_shelf---v010)

---

#### `lti` - `v0.1.0`

##### Features

 - **lti**: implement AGS and NRPS service clients. ([bc3a16ad](https://github.com/fischerscode/lti.dart/commit/bc3a16adaf27e39ce6f89afe601dfc1225a87e61))
 - **lti**: add scoped OAuth service token client. ([8330ee9f](https://github.com/fischerscode/lti.dart/commit/8330ee9ff370a951231e140272f994265d8f56b7))
 - report safe server-side launch validation diagnostics. ([fb7df364](https://github.com/fischerscode/lti.dart/commit/fb7df364146d0e1cdab0e19d21612481f0f44378))
 - add verified deep linking selection and return flow. ([795fb259](https://github.com/fischerscode/lti.dart/commit/795fb25924a1da8678786583f15cebee9562a338))
 - **lti**: add tool signing and public key rotation. ([034089bb](https://github.com/fischerscode/lti.dart/commit/034089bbe572263bbc80307f76da7074c1633b79))
 - **lti**: validate core vocabularies and optional launch claims. ([a544d077](https://github.com/fischerscode/lti.dart/commit/a544d077f25bce4654b0462bf451e857884dc8b2))
 - initialize LTI tool workspace and secure resource launches. ([db0475f7](https://github.com/fischerscode/lti.dart/commit/db0475f75d76591731adbff5363929ee29fe8562))

##### Bug Fixes

 - **lti**: normalize standard short NRPS context roles. ([68576731](https://github.com/fischerscode/lti.dart/commit/68576731907e0333ca13e747072dd266e817507d))
 - **lti**: identify invalid NRPS member fields without exposing values. ([d88965dc](https://github.com/fischerscode/lti.dart/commit/d88965dcee50187b0cb243664bf612df330fc48c))
 - **lti**: diagnose NRPS response validation failures safely. ([670f3e57](https://github.com/fischerscode/lti.dart/commit/670f3e57def0199b998223ac6c7465cfa3272815))
 - **lti**: support opt-in Moodle token content type compatibility. ([6932830b](https://github.com/fischerscode/lti.dart/commit/6932830b5c99513592d4c33aa43be1707ae919da))
 - **lti**: expose safe OAuth response validation diagnostics. ([5391062f](https://github.com/fischerscode/lti.dart/commit/5391062fba943b80314bec97851d495e161727e1))
 - **lti**: normalize legacy standard context types. ([c9e4faf6](https://github.com/fischerscode/lti.dart/commit/c9e4faf65c42cde3b982c656dfdb8e1474551c9b))

##### Code Refactoring

 - **lti**: simplify immutable models and service parsing. ([3a41f340](https://github.com/fischerscode/lti.dart/commit/3a41f3408be69a47e2a6728b87d87a6f0ca92846))

##### Documentation

 - **lti**: add runnable offline launch example. ([15399ab9](https://github.com/fischerscode/lti.dart/commit/15399ab99405b51e591e110f26c0513de016464d))
 - correct integration guides and published package setup. ([225096d3](https://github.com/fischerscode/lti.dart/commit/225096d31259d3d8e25c5f35e70fbf397744f87e))
 - make package getting started guides beginner friendly. ([95ac628b](https://github.com/fischerscode/lti.dart/commit/95ac628b74f1945806e8d9a1669edf3ff48717e9))
 - document public APIs and enforce documentation checks. ([f16e14d3](https://github.com/fischerscode/lti.dart/commit/f16e14d3c2db78ecfa8e93a7ff0ccb5d9bcfd769))

#### `lti_shelf` - `v0.1.0`

##### Features

 - **lti_shelf**: add explicit ByCS AGS write test workflow. ([e2649abc](https://github.com/fischerscode/lti.dart/commit/e2649abcbe690b24c8dcc88bb083feed639fdf9f))
 - **lti_shelf**: add opt-in ByCS service read tests. ([e1184cf5](https://github.com/fischerscode/lti.dart/commit/e1184cf5e0ad018f0996fcb83f595eb5d982346b))
 - **lti_shelf**: add opt-in HTTP access diagnostics. ([2ec5e08b](https://github.com/fischerscode/lti.dart/commit/2ec5e08b9254fbd02b565e0cdeb0b7f1ccf2a1ef))
 - **lti_shelf**: add opt-in JWKS retrieval diagnostics. ([24237f13](https://github.com/fischerscode/lti.dart/commit/24237f13dd8d1c98a2b6e96f09ac60e58591bde2))
 - **lti_shelf**: add browser-bound deep linking test selection. ([d8dde381](https://github.com/fischerscode/lti.dart/commit/d8dde38148e5e20209bd88cd276be2f15c3f65b7))
 - report safe server-side launch validation diagnostics. ([fb7df364](https://github.com/fischerscode/lti.dart/commit/fb7df364146d0e1cdab0e19d21612481f0f44378))
 - add HTTPS resource launch integration runner. ([da3b4edb](https://github.com/fischerscode/lti.dart/commit/da3b4edb8607b1e9da23d0d488b6310390ef8d83))
 - add safe LTI login metadata diagnosis. ([257797aa](https://github.com/fischerscode/lti.dart/commit/257797aad2d54e1cf9765de0b99d21fc2c6a173e))
 - add verified deep linking selection and return flow. ([795fb259](https://github.com/fischerscode/lti.dart/commit/795fb25924a1da8678786583f15cebee9562a338))
 - **lti**: add tool signing and public key rotation. ([034089bb](https://github.com/fischerscode/lti.dart/commit/034089bbe572263bbc80307f76da7074c1633b79))
 - **lti**: validate core vocabularies and optional launch claims. ([a544d077](https://github.com/fischerscode/lti.dart/commit/a544d077f25bce4654b0462bf451e857884dc8b2))
 - initialize LTI tool workspace and secure resource launches. ([db0475f7](https://github.com/fischerscode/lti.dart/commit/db0475f75d76591731adbff5363929ee29fe8562))

##### Bug Fixes

 - **lti**: identify invalid NRPS member fields without exposing values. ([d88965dc](https://github.com/fischerscode/lti.dart/commit/d88965dcee50187b0cb243664bf612df330fc48c))
 - **lti**: diagnose NRPS response validation failures safely. ([670f3e57](https://github.com/fischerscode/lti.dart/commit/670f3e57def0199b998223ac6c7465cfa3272815))
 - **lti**: support opt-in Moodle token content type compatibility. ([6932830b](https://github.com/fischerscode/lti.dart/commit/6932830b5c99513592d4c33aa43be1707ae919da))
 - **lti**: expose safe OAuth response validation diagnostics. ([5391062f](https://github.com/fischerscode/lti.dart/commit/5391062fba943b80314bec97851d495e161727e1))
 - **lti_shelf**: preserve origin for selection form submissions. ([c14bca4d](https://github.com/fischerscode/lti.dart/commit/c14bca4d272ab3d89d6a15bdba157a8fa45062d1))
 - **lti_shelf**: support partitioned cookies and trusted iframe embedding. ([6a9f1c38](https://github.com/fischerscode/lti.dart/commit/6a9f1c3894dede66ceabcb60352681ac51968171))

##### Documentation

 - correct integration guides and published package setup. ([225096d3](https://github.com/fischerscode/lti.dart/commit/225096d31259d3d8e25c5f35e70fbf397744f87e))
 - make package getting started guides beginner friendly. ([95ac628b](https://github.com/fischerscode/lti.dart/commit/95ac628b74f1945806e8d9a1669edf3ff48717e9))
 - document public APIs and enforce documentation checks. ([f16e14d3](https://github.com/fischerscode/lti.dart/commit/f16e14d3c2db78ecfa8e93a7ff0ccb5d9bcfd769))

