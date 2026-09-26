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
at `/` and `/health`. Other paths return 404; only GET/HEAD are accepted. It does
not implement LTI or accept launch tokens. Stop with Ctrl+C before starting the
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

## Next integration step

After connectivity succeeds, configure the actual LTI adapter with ByCS's issuer,
client ID, deployment ID, authorization endpoint and platform JWKS URL. Its
public origin is `https://ltitest.schulzeug.eu:55531`; include the port in all
registered URLs. Planned paths are `/lti/login`, `/lti/launch`, `/lti/jwks` and
`/activity`. The existing Shelf example still requires this registration and runs
HTTP behind a proxy; it is not the TLS probe above.
