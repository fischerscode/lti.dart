# ByCS integration environment

The development server runs in WSL. An external SSH server supplies the public
IPv4 endpoint. TLS terminates in WSL, not on the external server:

```text
https://ltitest.schulzeug.eu
    -> external TCP listener :443
    -> reverse SSH tunnel
    -> WSL 127.0.0.1:8443 (HTTPS)
```

The public DNS A record must point to the external server. If an AAAA record
exists, that IPv6 endpoint must also serve the same application, or remove the
AAAA record for this test hostname.

## Tunnel

Run in the same WSL distribution as Dart and leave the terminal open:

```sh
ssh -N -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -R 0.0.0.0:443:127.0.0.1:8443 \
  USER@SSH-SERVER
```

The SSH server needs to permit remote TCP forwarding and the requested public
binding (`GatewayPorts clientspecified`), with TCP 443 reachable through its
firewall. Successful SSH login alone does not establish external reachability.

## Certificate

Request a certificate in WSL using Certbot's manual DNS challenge:

```sh
sudo certbot certonly --manual --preferred-challenges dns \
  --cert-name ltitest.schulzeug.eu -d ltitest.schulzeug.eu
```

Publish the TXT value provided by Certbot at
`_acme-challenge.ltitest.schulzeug.eu`, wait for public DNS visibility, then
continue the prompt. This manual flow needs a new challenge when renewing.
See the [Certbot manual plugin documentation](https://eff-certbot.readthedocs.io/en/latest/using.html#manual).

The unprivileged Dart process uses a restricted local copy. From the repository
root, run these commands after issuance and after every renewal:

```sh
install -d -m 700 .local/bycs/tls
sudo install -m 600 -o "$(id -u)" -g "$(id -g)" \
  /etc/letsencrypt/live/ltitest.schulzeug.eu/fullchain.pem \
  .local/bycs/tls/fullchain.pem
sudo install -m 600 -o "$(id -u)" -g "$(id -g)" \
  /etc/letsencrypt/live/ltitest.schulzeug.eu/privkey.pem \
  .local/bycs/tls/privkey.pem
```

`.local/` is ignored by Git. The TLS private key must remain private and is
separate from the future LTI signing key. Do not run the Dart application as root.

## Connectivity probe

Start in a second WSL terminal from the repository root:

```sh
fvm dart run tool/https_probe.dart
```

This binds only WSL loopback on port 8443 and serves a plain connectivity message
at `/` and `/health`. The health routes accept GET/HEAD. `/lti/login` additionally accepts GET and
form POST for registration diagnosis (see below); other paths return 404.
It does not authenticate LTI launches. Stop with Ctrl+C before starting the
actual integration server on the same port.

Verify the certificate and local TLS listener without bypassing validation:

```sh
curl --noproxy '*' --resolve ltitest.schulzeug.eu:8443:127.0.0.1 \
  https://ltitest.schulzeug.eu:8443/health
```

Then verify the complete public path, preferably also from a separate network:

```sh
curl --noproxy '*' https://ltitest.schulzeug.eu/health
```

A passing request proves HTTPS reachability from that client. ByCS's own
outbound-port policy still needs verification during the JWKS integration.

## Read registration metadata from a ByCS launch

If ByCS does not expose registration details in its course-tool menu, restart
this probe and create a course activity using the previously registered tool.
Open that activity from ByCS. Its configured login URL must be
`https://ltitest.schulzeug.eu/lti/login`.

The diagnostic page displays only `iss`, `client_id` and `lti_deployment_id`
when supplied. It neither stores request data nor logs hints, JWTs or cookies.
Inputs are bounded and duplicate parameters rejected. These are **unsigned,
unverified login parameters**, not proof of a successful launch and not an
automatically trusted registration. Record the values from your own deliberate
ByCS test, validate the platform endpoints, and configure an explicit allowlist
before enabling actual authentication. A missing parameter remains missing; the
probe does not guess identifiers. The response intentionally stops before the
OIDC redirect.

## Start the resource-launch integration server

The runner `packages/lti_shelf/example/bycs_server.dart` serves HTTPS directly
in WSL on port 8443. It reads `.local/bycs/registration.json` (override with
`LTI_CONFIG_FILE`) with these fields:

```json
{
  "tool_origin": "https://ltitest.schulzeug.eu",
  "issuer": "https://lernplattform.bycs.de",
  "client_id": "YOUR_CLIENT_ID",
  "deployment_id": "YOUR_DEPLOYMENT_ID",
  "authentication_endpoint": "https://lernplattform.bycs.de/mod/lti/auth.php",
  "jwks_uri": "https://lernplattform.bycs.de/mod/lti/certs.php",
  "token_endpoint": "https://lernplattform.bycs.de/mod/lti/token.php",
  "signing_key_file": ".local/bycs/signing-key.pem",
  "signing_key_id": "YOUR_UNIQUE_KEY_ID",
  "tls_certificate_file": ".local/bycs/tls/fullchain.pem",
  "tls_private_key_file": ".local/bycs/tls/privkey.pem"
}
```

Use the actual registration values from your deliberate platform setup. The
ByCS JWKS endpoint was observed returning an RSA key over HTTPS; auth and token
URLs responded; subsequent live browser results are recorded below.
The token endpoint is configured for future use; this runner requests no service
tokens. Registration data stays local, outside Git.

Generate a separate RSA signing key once, if one does not already exist:

```sh
(umask 077; test -e .local/bycs/signing-key.pem || \
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out .local/bycs/signing-key.pem)
```

Keep the SSH tunnel running. Stop the probe with Ctrl+C and run from the root:

```sh
fvm dart run packages/lti_shelf/example/bycs_server.dart
```

Public paths:

- `/health`: server readiness; not evidence of a successful LTI launch.
- `/lti/jwks`: public LTI signing keys; never private or TLS keys.
- `/lti/login`: registered OIDC login initiation, no longer a diagnostic echo.
- `/lti/launch`: signed resource callback, verified using the library.
- `/activity`: registered resource target; direct access only explains how to launch.

Open the activity from ByCS in a new window. Success displays
`LTI 1.3 resource launch verified.` without names, emails, user identifiers, course
identifiers or tokens. Failures display the library's safe error code. These
results establish protocol verification, not authorization for an application.

On a rejection, the runner prints `LTI <code>: <reason>` in the WSL terminal.
The reason identifies the failed check or field without printing claim values,
JWTs, cookies or login hints. The browser still receives only the generic error
code. Restart the runner after code updates and always start a fresh activity
launch from ByCS; callback attempts consume the login transaction.

This runner supports resource launches and a fixed Deep Linking test selection.
Keep AGS and NRPS disabled in ByCS. It uses in-memory transactions and selection
sessions for a single development process; restarting invalidates pending logins. Use a test course, not a public
production deployment. The earlier diagnostic runner remains separate and does
not feed registrations into this server automatically.

### Interoperability findings

A live ByCS attempt reached context validation after the local Windows/WSL clock
was synchronized (it had lagged external HTTPS timestamps by about 84 seconds).
The next failure was the context vocabulary check. Moodle 4.5's
[launch builder](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/mod/lti/locallib.php)
sends short context names such as `CourseSection`. The library now normalizes
only the aliases explicitly listed in Core Appendix A.1. This is a targeted
compatibility correction; the actual ByCS payload was not stored or inspected.

On 2026-09-27 the operator reported a successful fresh resource launch from the
real ByCS course after this correction (code commit `c9e4faf`). The integration
runner displayed `LTI 1.3 resource launch verified.` and confirmed signature,
issuer, audience, deployment, state and nonce validation. It reported a present
user, a present context and one role. This is operator-reported live integration
evidence, not a replayable captured-token test; no personal claims were recorded.

This verifies one resource-launch path through the public HTTPS/SSH setup.
At that stage, Deep Linking and embedded selection were still pending; subsequent
results are recorded below. ByCS retrieval of tool JWKS, broader role/browser
coverage, AGS and NRPS remain unverified against the live platform. This result
does not establish complete conformance or application authorization.

## Live Deep Linking test

Restart the integration runner after updating the code, keeping the SSH tunnel
open. Edit the existing ByCS tool registration:

- Enable **Unterstützt Deep Linking (Content-Item Message)**.
- Set **Inhalts-URL** to `https://ltitest.schulzeug.eu/activity`.
- Keep **Umleitungs-URI(s)** as `https://ltitest.schulzeug.eu/lti/launch`.
- Keep the public keyset at `https://ltitest.schulzeug.eu/lti/jwks`.
- Keep a new-window launch container initially and leave services disabled.

The content-selection target intentionally matches the existing allowed resource
URL. The signed message type selects the handler, so separate login and redirect
URLs are not needed. The selection UI is opened by a verified
`LtiDeepLinkingRequest`, never by directly navigating to `/activity`.

Create a new course activity using this tool. Use the content-selection action
(typically **Inhalt auswählen**) in the activity editor. The verified request
opens the test selection page. Click **Testinhalt hinzufügen**, return to ByCS,
and save the activity. Open the newly created activity from the course; expect
`LTI 1.3 resource launch verified.` and
`Deep Linking test marker present: true`. The marker is a fixed custom parameter,
not a user or course identifier. The returned item includes no gradebook line item.

Repeat content selection separately and click **Abbrechen**. ByCS should return
to its editing UI without receiving any new content items. Platform persistence
and cancellation behavior must be observed in the real browser; local tests do
not establish live interoperability. A successful return shows ByCS can validate
the tool signature with its public key (possibly cached), not necessarily that
it fetched JWKS again during that exact attempt.

The example permits selection only for a present user with a recognized context
Instructor, ContentDeveloper or Administrator role (including standard subroles).
That is the example's policy, not an LTI requirement. It stores the verified launch
server-side for at most ten minutes, uses independent secure HttpOnly cookies for
parallel selections, checks the POST Origin and CSRF token, bounds form/session
sizes and consumes each session before signing. If a browser blocks cookies,
use a top-level launch where the platform permits it. On expiry or server restart, start a new selection
from ByCS. Production tools need shared session storage and their own authorization.

### Embedded selection and registration details

ByCS shows the Client-ID when **editing the tool after creating it** (confirmed
by the tester). The content selection opens in a modal iframe, independently of
the activity's default launch container.

The browser test exposed Dart HttpServer's default
`X-Frame-Options: SAMEORIGIN`, which blocked the ByCS iframe. The runner removes
that default before accepting requests and adds
`frame-ancestors 'self' <configured issuer origin>` to every response, preserving
the selection and return forms' existing CSP directives.

The runner also enables `Partitioned` on both OIDC binding and selection cookies
(Secure, HttpOnly, SameSite=None), including deletion. CHIPS-capable browsers can
keep these cookies under the embedding platform's partition even when ordinary
third-party cookies are blocked. Missing or ambiguous binding cookies still
reject the callback; this is not a cookie-free authentication fallback.
See [MDN's CHIPS documentation](https://developer.mozilla.org/en-US/docs/Web/Privacy/Guides/Third-party_cookies/Partitioned_cookies).

After updating, restart the Dart runner, close the failed modal, and start a
fresh **Inhalt auswählen** flow from ByCS. Existing states cannot be reused.
The subsequent selection/return/resource-launch result is recorded below.
Cancellation was subsequently confirmed with a directly configured RSA key
(see below); broader browser cookie-policy coverage remains to be verified.

The subsequent browser test reached the selection page, but clicking its button
returned `Selection origin mismatch.`. The selection page had inherited
`Referrer-Policy: no-referrer`, which makes native form POSTs send `Origin: null`
([MDN](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Referrer-Policy#effect_on_the_origin_header)).
It now uses `strict-origin`, and the adapter preserves explicitly supplied
application referrer policies. Only the origin is disclosed, with no path or
query string. The return-to-platform form keeps `no-referrer`.
Missing, null and foreign origins still fail, as do missing cookies or invalid
CSRF tokens. Restart the runner and begin a fresh selection to retest.


### Migration to HTTPS port 443

The tester moved the public SSH listener to port 443 on another IP, keeping the
hostname. The local integration configuration now uses
`https://ltitest.schulzeug.eu`; the WSL destination remains 127.0.0.1:8443.
Restart the runner after changing its configuration. Update all ByCS tool URLs
(login, redirect, activity/content and JWKS) to omit the old port, and update
existing activity URLs where needed. Start a fresh selection rather than reuse
a pending launch from the old origin. The hostname certificate and existing
LTI signing key can stay in use.

This follows a ByCS `fix_jwks_alg(): ... array, null given` error on the Deep
Linking return. The old public JWKS URL returned HTTP 200 and valid JSON during
our check, but this did not prove reachability from ByCS itself. A server-side
port restriction is a hypothesis, not a confirmed ByCS configuration.


### Confirmed Deep Linking round trip with a directly configured RSA key

On 2026-09-27, the operator reported that switching ByCS from the keyset URL to
the tool's directly configured RSA public key succeeded. After content selection
and return to ByCS, the selected resource launched and the runner displayed:

- `LTI 1.3 resource launch verified.`
- Signature, issuer, audience, deployment, state and nonce validated.
- User present: true; context present: true; role count: 1.
- `Deep Linking test marker present: true`.

This is operator-reported evidence for the embedded test selection, signed
Deep Linking return accepted by ByCS, and subsequent resource launch carrying
the fixed custom marker. It is not evidence of successful JWKS retrieval,
complete LTI Advantage coverage or application authorization. Other content
types and additional browsers/roles remain untested live.

The keyset-loading error also occurred on port 443. An independent HTTPS fetch
of `https://ltitest.schulzeug.eu/lti/jwks` returned HTTP 200 and valid JWKS, but
ByCS still reported `fix_jwks_alg(): ... array, null given`. The cause of that
retrieval/configuration failure remains unresolved; a nonstandard port alone
does not explain the observed results.

The direct public key was derived from the existing LTI signing key, without
rotating it, and saved locally as `.local/bycs/signing-public-key.pem`. Only its
public PEM contents were intended for the ByCS registration. Direct-key mode
does not exercise JWKS refresh or rotation.


### Confirmed cancellation with a directly configured RSA key

The operator also confirmed on 2026-09-27 that **Abbrechen** works with the
direct RSA public key configured in ByCS. The intervening cancellation attempt
that produced the same JWKS-loading error had been made after switching the
registration back to keyset-URL mode. That failure therefore does not establish
a separate cancellation defect.

The live test record now covers selection, signed return, subsequent resource
launch with the custom marker, and cancellation using the directly configured
public key. ByCS retrieval of the tool JWKS remains unresolved.


### Targeted JWKS retrieval diagnosis

An independent check on 2026-09-27 resolved the hostname to 178.238.224.202,
returned no AAAA record, verified TLS successfully with curl and OpenSSL, and
received HTTP 200 with public RSA JWKS. These observations do not establish
ByCS-side DNS resolution, network access or the saved registration URL.

Restart the runner with opt-in request diagnostics:

```sh
BYCS_JWKS_DIAGNOSTICS=1 fvm dart run packages/lti_shelf/example/bycs_server.dart
```

First confirm logging from a separate WSL terminal:

```sh
curl --noproxy '*' --fail --silent --show-error --max-time 10 \
  'https://ltitest.schulzeug.eu/lti/jwks?probe=local'
```

Expect a runner line containing `method=GET probe=local status=200`. Then set
the ByCS public key type back to keyset URL, enter exactly
`https://ltitest.schulzeug.eu/lti/jwks?probe=bycs`, save, and start a fresh
content selection and return. Do not open that marked URL yourself during the
test. Send the resulting JWKS diagnostic lines alongside the browser outcome.

The label is only a correlation aid, not proof of the request's identity.
Only UTC timestamp, a fixed method category, an allowlisted probe label and
response status are logged. Raw queries, headers, IP addresses, bodies,
tokens and cookies are excluded. Logging is off without the environment flag.

- A correlated `probe=bycs status=200` shows the runner prepared a successful
  response, not that ByCS received or parsed it. Check registration selection,
  intermediary responses and ByCS server logs if the error persists.
- If the control request logs but the fresh failing ByCS attempt produces no
  JWKS line, check the saved keyset URL and selected tool registration, then
  ByCS DNS/TLS/egress restrictions with the platform operator. Lack of a log
  alone does not identify which of these failed.
- Other response statuses or an unmarked request help identify an unexpected
  method, configuration or request path through the test setup.

Keep direct RSA mode available for functional testing. No change to signature
verification or key material is needed for these diagnostics.
