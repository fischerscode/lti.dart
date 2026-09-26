# ByCS integration environment

The development server runs in WSL. An external SSH server supplies the public
IPv4 endpoint. TLS terminates in WSL, not on the external server:

```text
https://ltitest.schulzeug.eu:55531
    -> external TCP listener :55531
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
  -R 0.0.0.0:55531:127.0.0.1:8443 \
  USER@SSH-SERVER
```

The SSH server needs to permit remote TCP forwarding and the requested public
binding (`GatewayPorts clientspecified`), with TCP 55531 reachable through its
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
curl --noproxy '*' https://ltitest.schulzeug.eu:55531/health
```

A passing request proves HTTPS reachability from that client. ByCS's own
outbound-port policy still needs verification during the JWKS integration.

## Read registration metadata from a ByCS launch

If ByCS does not expose registration details in its course-tool menu, restart
this probe and create a course activity using the previously registered tool.
Open that activity from ByCS. Its configured login URL must be
`https://ltitest.schulzeug.eu:55531/lti/login`.

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
  "tool_origin": "https://ltitest.schulzeug.eu:55531",
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
URLs responded but the complete ByCS launch still needs a live browser test.
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

This runner currently supports resource launches only: keep Deep Linking, AGS
and NRPS disabled in ByCS. It uses in-memory transactions for a single development
process; restarting invalidates pending logins. Use a test course, not a public
production deployment. The earlier diagnostic runner remains separate and does
not feed registrations into this server automatically.

### Interoperability findings

A live ByCS attempt reached context validation after the local Windows/WSL clock
was synchronized (it had lagged external HTTPS timestamps by about 84 seconds).
The next failure was the context vocabulary check. Moodle 4.5's
[launch builder](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/mod/lti/locallib.php)
sends short context names such as `CourseSection`. The library now normalizes
only the aliases explicitly listed in Core Appendix A.1. This is a targeted
compatibility correction; the actual ByCS payload was not stored or inspected,
and a fresh live launch is required to confirm it resolves that failure.
