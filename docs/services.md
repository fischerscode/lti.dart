# LTI Advantage services

The tool-side clients cover [AGS 2.0](https://www.imsglobal.org/spec/lti-ags/v2p0/)
and [NRPS 2.0](https://www.imsglobal.org/spec/lti-nrps/v2p0/). Their capabilities
are parsed on verified launches as `launch.ags` and `launch.nrps`. Absence is
normal and disables the corresponding operations. Local tests and reported live
ByCS tests cover membership reads and grade workflows; this is not formal
certification. See the [ByCS test guide](bycs-testing.md).

## Constructing clients

```dart
final services = LtiServiceClient(
  launch: verifiedLaunch,
  oauth: oauthClient,
  client: httpClient,
  // Administrator-provisioned; never derive this set from a launch/response.
  allowedOrigins: {Uri.parse('https://platform.example')},
);
```

Each client belongs to one verified registration/deployment/context. Reuse the
OAuth client and caller-owned HTTP client across these instances. Do not reuse
a service client across unrelated launches, users or tenants. Applications must
authorize operations independently; a verified launch/role is not permission
to change a grade or export a roster.

Every request, returned line-item endpoint and pagination/differences URL is
checked against the explicit HTTPS origin allowlist. Page traversal also
requires the original endpoint's origin. Credentials, fragments, HTTP URLs and
redirects are rejected. No bearer credentials are forwarded to an unapproved
host. These checks are not DNS/IP pinning: configure network egress controls
for the trusted platform origins. Platforms on additional service hosts need
explicit administrator approval of those origins.

## AGS

```dart
final ags = services.ags;
await for (final item in ags.allLineItems(
  resourceLinkId: resourceLaunch.resourceLink.id,
  limit: 50,
)) {
  // Use item.id, label, scoreMaximum, resourceId, tag, dates, gradesReleased.
}

final created = await ags.createLineItem(
  LtiLineItem(
    label: 'Exercise 42',
    scoreMaximum: 10,
    resourceLinkId: resourceLaunch.resourceLink.id,
    resourceId: 'exercise-42',
    tag: 'grade',
  ),
);
final current = await ags.getLineItem(lineItem: created.id);
final replacement = LtiLineItem.fromJson({...current.json, 'label': 'Updated'});
await ags.updateLineItem(current, replacement);

await ags.publishScore(
  LtiScore(
    userId: learnerSubject,
    timestamp: changedAt,
    activityProgress: LtiActivityProgress.completed,
    gradingProgress: LtiGradingProgress.fullyGraded,
    scoreGiven: 8,
    scoreMaximum: 10,
  ),
  lineItem: created.id,
);
await for (final result in ags.allResults(lineItem: created.id)) {
  // Result is the platform's gradebook value, not necessarily our last score.
}
await ags.deleteLineItem(lineItem: created.id);
```

This example shows the operations in a column's lifecycle, including deletion.
Choose the operations your workflow needs; do not recreate or delete a column
on each launch. It assumes an authorized `resourceLaunch`, `learnerSubject` and
`changedAt`, with the latter taken from the persisted score change. Persist
monotonically increasing timestamps per line item/user and serialize updates across workers; do not
generate a fresh timestamp simply to retry an uncertain write. The library
formats subsecond UTC timestamps, but cannot order business events across
application instances.

The signed AGS claim advertises allowed scopes. Reads prefer lineitem.readonly
when available, otherwise lineitem. Writes, score publication and result reads
require their respective scopes before token acquisition. Missing capabilities
fail locally. Resource-link identifiers must be platform-issued IDs belonging
to the same tool/context; never invent them.

The typed models handle progress values, optional scoring user/comment,
submission times, nullable platform dates/metadata and score clearing (null
scoreGiven). Extra credit above scoreMaximum is valid. AGS extensions use
fully qualified URL keys and JSON values; unknown response properties remain
immutable and round-trip through line item updates. PUT is a complete
replacement: the API rejects changes to the original id/resourceLinkId.
Concurrent modification protection and resolving uncertain write outcomes
belong to the application/platform.

Scores and results append /scores or /results to the line-item path while
preserving its query. Use lineItems/results for a single LtiServicePage or
allLineItems/allResults for bounded streams. Filters are applied only to the
initial request; next links are followed as provided.

## NRPS

```dart
final nrps = services.nrps;
final page = await nrps.memberships(
  role: LtiRoles.learner,
  resourceLinkId: resourceLaunch.resourceLink.id,
  limit: 100,
);
for (final member in page.items) {
  // Only userId and roles are guaranteed. Name/email may be absent.
}
// Separate later operation: process the full snapshot before applying changes.
final later = page.differences;
if (later != null) {
  await for (final changed in nrps.allMemberships(differencesUrl: later)) {
    // Apply Active, Inactive or Deleted to an application-owned roster.
  }
}
```

NRPS requires advertised version 2.0 and requests contextmembership.readonly.
The `role`, `resourceLinkId` (wire parameter `rlid`) and `limit` filters are
supported. Member roles normalize eight exact short context role names to
canonical URIs while retaining the original values in `LtiMember.json`; see
[NRPS compatibility](bycs-testing.md#nrps-short-context-roles).
Status defaults to Active; Deleted is accepted only for a differences query. Per-member message claims and unknown
fields are preserved, not interpreted as authenticated launches. Response
context must match the launch context when that context was supplied.

The example reads only one snapshot page. For a complete roster, follow
`page.next` or use `allMemberships` before applying later differences. Persist a
differences cursor only after successfully processing the associated snapshot
or changes feed.

For a differences report's individual pages, call
`memberships(page: differencesUrl, differences: true)` and retain that flag on
subsequent pages. `allMemberships(differencesUrl: ...)` carries this mode
automatically. The API exposes both `next` and `differences` links. Snapshot and
changes-feed reconciliation and persistence are application responsibilities.

## Transport and local verification

Service HTTP requests have time and response-size limits. OAuth token acquisition
has a separate timeout; the service timeout does not bound the entire operation.
Streams also bound page count
and detect repeated next URLs; individual-page APIs leave traversal under the
caller's control. Link parsing handles relative URLs, quoted commas, multiple
relations and rejects duplicate next/differences relations; links with an
`anchor` parameter are ignored, even if the anchor identifies the current URL.
Content types and response models are checked before returning data.

HTTP 401 evicts the exact rejected OAuth token. No operation, including GET, is
automatically retried; choose an application retry policy appropriate to the
operation. Errors expose a category, optional HTTP status and fixed validation
metadata
(`responseIssue` and, for member validation, `memberField`), never response
bodies or bearer tokens. The caller owns and closes its transport, which should
honor `AbortableRequest` for timely cancellation (as IOClient does). A successful
response means the platform accepted the operation, not a durable application
audit record.

Local tests cover real signed launch capabilities, OAuth integration, CRUD,
scores/results, filters, multi-page traversal, NRPS missing personal fields,
differences, scope failures, context mismatch, foreign URLs, redirect/error
handling, 401 invalidation, size/time bounds and model immutability.
AGS/NRPS/Deep Linking errata URLs returned HTTP 403 during the 2026-09-27 review;
the available final specifications were used. Recheck errata before a formal
conformance claim.
