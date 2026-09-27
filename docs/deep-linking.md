# Deep Linking

The tool-side flow implements [Deep Linking 2.0](https://www.imsglobal.org/spec/lti-dl/v2p0/)
within LTI 1.3. The message version remains `1.3.0`. This is an implementation,
not certification. A ByCS resource selection/return and cancellation with a
direct RSA key have been reported successful; see [test record](bycs-testing.md).

## Consumer API

Configure a signer as described in [signing.md](signing.md), then use
`LtiTool.completeLaunch` to receive either `LtiResourceLaunch` or
`LtiDeepLinkingLaunch`. Existing `completeResourceLaunch` consumers remain
resource-only. Shelf dispatches the same callback URL through
`onResourceLaunch` and optional `onDeepLinkingLaunch` handlers. Without a
selection handler it rejects selection requests.

A host application's selection handler stores the verified launch in a protected
server-side session, authorizes the user and renders its own selection UI. The
later submission handler checks that session, its expiry and CSRF protection,
then creates the response:

```dart
final message = await tool.createDeepLinkingResponse(
  launch: verifiedSelectionLaunch,
  items: [
    LtiContentItem.ltiResourceLink(
      url: Uri.parse('https://tool.example/activity'),
      title: 'Exercise 42',
      custom: {'exercise': '42'},
      lineItem: LtiDeepLinkingLineItem(scoreMaximum: 10),
    ),
  ],
);
return deepLinkingFormResponse(message); // package:lti_shelf
```

These variables belong to the consuming tool; the library does not supply its
UI or application sessions. Do not reconstruct a verified launch from browser
JSON or use the original id_token as a reusable session credential. The library
consumes the login transaction once. Application authorization is still needed,
especially when the request omits roles or user information.

For cancellation, pass no items. `message`, `log`, `errorMessage` and `errorLog`
add optional signed response messages. The builder reloads the registration and
checks that its deployment and original login target are still enabled. The
response includes the exact opaque `data` JSON value when present (including
empty values), a fresh nonce, and a short-lived RS256 signature. Its audience is
the verified platform issuer. Return URLs come from the signed request.

## Content and negotiation

Named `LtiContentItem` constructors cover all five standard types: resource
links, ordinary links, files, HTML and images. `LtiDeepLinkingLineItem` models
gradebook creation metadata. Optional nested presentation, icon/thumbnail and
availability/submission metadata can be supplied through `properties` or
`LtiContentItem.fromJson`; these are validated and recursively frozen.
Extensions are retained; use fully-qualified URLs for extension property keys
and new type names. Standard nested metadata currently uses JSON maps rather
than dedicated Dart classes.

The selection builder checks accepted types, explicit presentation targets,
item count and file MIME hints. Omitted `accept_multiple` is treated
conservatively as false. An empty selection is always supported. A file's
`mediaType` is a local negotiation hint and is not serialized as a File property.
MIME matching currently supports exact media types, `type/*` and `*/*`; media
range parameters are not interpreted. Unsupported parameterized ranges fail
closed. `accept_lineitem` remains nullable: false means the platform ignores
line items, rather than making them invalid. `autoCreate` is informational;
the tool cannot guarantee that the platform persists the returned selection.

All resource URLs follow this library's stricter HTTPS-only policy. Item URLs
are not fetched. For links to this tool, register the eventual launch URL in
`targetLinkUris`; resource-specific custom parameters can keep this URL stable.
HTML content is signed, never rendered by the return-form helper. Sanitization
of HTML when displaying it belongs to the consuming platform or application.

## Protocol and verification decisions

Deep Linking requests share the existing signature, issuer/audience,
time, nonce, state, deployment and browser-binding checks. They require
`deep_linking_settings` but do not require `resource_link` or roles. A supplied
`target_link_uri` must match the original registered login target. When absent,
the verified launch retains the target from the login transaction; no unsigned
callback value is accepted as a substitute.

The Shelf helper emits a POST form with uppercase `JWT`, attribute escaping,
a nonce-bound auto-submit script, a manual button, no-store and no-referrer
headers. Its CSP restricts form destinations to HTTPS and disables other content
sources. It remains usable inside an iframe subject to the platform's sandbox
and the documented third-party-cookie limitation.

Tests use real RSA signatures and a local simulated platform to cover selection,
response verification, subsequent resource launch, cancellation, opaque data,
all five content types, negotiation failures, malformed requests, output escaping
and replay. One live ByCS browser flow with a direct RSA key has been exercised;
other content types and broader browser/platform coverage remain part of the
interoperability milestone. The specification's linked errata page was unavailable during this
implementation; recheck it as part of that milestone.
