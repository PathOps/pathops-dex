# PathOps Dex

This repository does not maintain an independent Dex distribution.

It reproducibly builds selected upstream [Dex](https://github.com/dexidp/dex)
releases with a minimal PathOps patch set required by the PathOps Cell security
model.

Current patch set:

- `0001`: validates the accepted audiences of OIDC JWT subject tokens during
  RFC 8693 token exchange.
- `0002`: packaging only. Ships the upstream license and a PathOps notice
  inside the image.
- `0003`: opt-in operation-scoped delegated authorization (PathOps Decision
  0050): pushed authorization requests (RFC 9126) carrying RAR
  `authorization_details` (RFC 9396) and a delegate-signed PathOps
  Authorization Plan, a per-operation consent screen, operation grants, an
  Operation Authorization Token as the result of each consent, and
  Step-scoped tool tokens derived by the delegate. See
  [Delegation](#delegation).
- `0004`: `sessions.cookieEncryptionKeyFromEnv`: the session cookie
  encryption key from an environment variable (a Kubernetes Secret) instead of
  the configuration file, like `hashFromEnv` of static passwords.

Long-term goal: remove the functional patch once equivalent functionality is
available upstream, and consume official Dex images again.

## Why

PathOps Cells use Dex as their identity broker and token service. Kubernetes
workloads exchange their projected ServiceAccount tokens for short-lived tokens
issued by Dex, without static client secrets. For that, Dex must accept only
subject tokens minted for its own audience.

In upstream Dex v2.46.0, the OIDC connector verifies exchanged ID tokens with
go-oidc `SkipClientIDCheck`. Issuer, signature and expiry are checked, but the
subject token's `aud` claim is not.

The patch adds one opt-in connector option. When it is unset, behaviour is
identical to upstream. The behaviour was reported privately to the Dex
maintainers for classification.

## Configuration

```yaml
connectors:
  - type: oidc
    id: kubernetes
    name: Kubernetes workloads
    config:
      issuer: https://kubernetes.default.svc.cluster.local
      subjectTokenAudiences: ["https://dex.example.com"]
```

With `subjectTokenAudiences` set:

- an exchanged ID token is accepted only if its `aud` (string or array)
  contains one of the listed values;
- exchanged access tokens are rejected, because their audience cannot be
  verified through userinfo.

Run the image with `DEX_CONFIG_DISALLOW_UNKNOWN_FIELDS=true`. An unpatched Dex
then refuses to start with this configuration instead of silently ignoring the
option.

## Delegation

Patch `0003` adds an opt-in `delegation` section. It lets a confidential
*delegate* (the PathOps Tenant Control Plane) act for a user only within one
operation the user approved, without ever handling the user's own tokens.

```yaml
delegation:
  planClients: [pathops-cli]          # public clients that push plans (PAR)
  pushedRequestsValidFor: 90s         # request_uri lifetime (single use)
  maxPlanLifetime: 15m                # exp - iat of a plan
  grantsValidFor: 15m                 # operation grant, from approval
  tokensValidFor: 5m                  # derived tool token, never beyond the grant
  authorizationTokensValidFor: 5m     # Operation Authorization Token, never beyond the grant
  delegates:
    - client: pathops-tenant-control-plane   # a confidential staticClient
      name: PathOps Tenant Control Plane     # shown on the consent screen
      planIssuer: https://tcp.example.org    # "iss" of its plans
      planKeys:
        - {kid: tcp-plan-1, ed25519: <base64url raw public key>}
      tools:
        - name: forgejo
          displayName: Forgejo
          audiencePattern: 'u:[0-9]+:[0-9a-f-]{36}'
          detailTypes: [pathops_repository, pathops_webhook]
```

Flow:

1. The delegate computes the exact `authorization_details` of one operation
   and signs an **Authorization Plan** (EdDSA JWS, `typ`
   `pathops-authorization-plan+jwt`) binding them to the user (`sub`), the
   operation, its Application/Run, template provenance, the plan client and
   its redirect URI, the PKCE challenge (S256), each tool's audience and the
   SHA-256 of the canonical details. It is a delegate attestation, not an
   RFC 9101 Request Object.
2. The plan client (the PathOps CLI, a public client) pushes the request to
   `POST /par` with `authorization_details` and `pathops_authorization_plan`.
   Dex verifies the signature with the delegate's key and requires the pushed
   details to equal the plan's in canonical JSON (RFC 8785 restricted to
   ASCII strings and safe integers); any added, dropped, reordered or changed
   detail, PKCE challenge, redirect URI, client or subject fails. Dex answers
   a `request_uri` valid 90 s and usable once.
3. `/auth?client_id=…&request_uri=…` runs the normal login. The authenticated
   user must be the plan's subject. The consent screen (`delegation.html`)
   always shows, whatever `skipApprovalScreen` or stored consents say, and
   lists the operation's resources. `authorization_details` and plans are
   refused on the front channel.
4. Approval records an **operation grant** in the user's `UserIdentity`
   (reserved `Consents` key, no schema change). It becomes active only when
   the client redeems the code with the PKCE verifier. That token response
   carries only an **Operation Authorization Token** and the approved
   `authorization_details` (see below): the consent issues no access, ID or
   refresh token, so the client keeps the access token of its own login.
5. The delegate, authenticated with its client secret, derives a tool token
   with an RFC 8693 token exchange whose `subject_token` is the operation
   grant handle `pog1:<plan id>:<sub>` (`subject_token_type`
   `urn:pathops:params:oauth:token-type:operation-grant`), an `audience` and a
   subset of the grant's details. The token has `aud` = that tool audience
   (one value), `azp` = the delegate, the user's `sub`, exactly the requested
   details, a lifetime of at most `tokensValidFor` and never beyond the grant,
   and no refresh token. Public clients, other clients, other users' or
   other operations' grants, wider details and other audiences are refused.

### Operation Authorization Token

A PathOps extension, not an OAuth/OIDC standard. It is the portable, signed
proof that the user approved one plan, for the delegate only:

- a JWS signed with Dex's keys (the issuer's JWKS), with the explicit type
  `typ: pathops-oat+jwt` (RFC 8725 §3.11);
- returned in the `access_token` member of the code's token response (RFC
  6749 requires that member) with `issued_token_type`
  `urn:pathops:params:oauth:token-type:operation-authorization`;
- claims:

  | claim | value |
  | --- | --- |
  | `iss`, `sub` | this Dex, the user who approved |
  | `aud` | the plan's delegate (one value) |
  | `azp` | the plan client that redeemed the code |
  | `pathops_plan` | the plan id (the operation grant) |
  | `pathops_installation`, `pathops_operation` | the plan's Cell and operation |
  | `pathops_application`, `pathops_run` | the plan's Application and Run ids |
  | `authorization_details`, `authorization_details_sha256` | the exact approved details and their digest |
  | `iat`, `exp`, `jti` | at most `authorizationTokensValidFor`, never beyond the grant; unique |

The client presents it to the delegate next to its own access token, and the
delegate checks both and their binding. It authenticates nobody: Dex's
userinfo and introspection refuse it, its audience is no tool's, and it is
never a derivation subject (that is the grant handle, for the delegate only).
Delegation requires a signer that can type tokens (the local signer).

### Login sessions

Delegation works with Dex's experimental login sessions
(`DEX_SESSIONS_ENABLED=true` and `sessions:`): a session spares the user a new
password for the next operation, but each operation still shows its own
consent screen, and a request_uri is consumed before any session login. With
patch `0004` the cookie key can come from the environment:

```yaml
sessions:
  absoluteLifetime: 8h
  validIfNotUsedFor: 1h
  cookieEncryptionKeyFromEnv: DEX_SESSION_COOKIE_KEY   # 16, 24 or 32 bytes
```

The in-flight plan rides on a new `Delegation` field of auth requests and auth
codes, kept by the kubernetes and memory storages; Dex refuses to start with
`delegation` on other storages, and the frontend must provide
`delegation.html` (the bundled web directory does).

## Image

```text
docker.io/gborba/pathops-dex:v2.46.0-pathops.<n>
```

- Releases are published only by the `release` workflow, from tags. There is
  no `latest` tag.
- Pin the image by digest, which is shown in the release workflow summary.
- Image facts:
  - `linux/amd64`;
  - built with the upstream Dockerfile, so the runtime layout, user and
    entrypoint match the official Dex image;
  - `dex version` reports the release tag;
  - OCI labels name the upstream version and commit.

## Build locally

Requirements: `git`, Go (the version in upstream `go.mod`; the Go toolchain
downloads it automatically), Docker with BuildKit.

```bash
./scripts/test.sh      # fetch pinned upstream, apply patches, gofmt, go vet, go test ./...
./scripts/build.sh     # same source, docker build -> pathops-dex:local (never pushes)
./scripts/prepare-source.sh --clean
```

The patched upstream tree is created under `.work/dex` (ignored by Git).
`prepare-source.sh` fails if either of these happens:

- the upstream tag no longer resolves to `UPSTREAM_COMMIT`;
- a patch does not apply cleanly.

## Versioning

```text
<upstream-version>-pathops.<patch-revision>
```

For example, `v2.46.0-pathops.1` and `v2.46.0-pathops.2`. The revision restarts
at `1` for each new upstream version. The release workflow rejects tags whose
upstream part differs from `UPSTREAM_VERSION`.

## Upstream policy

- Each image is an exact upstream Dex tag plus the small patch set in
  `patches/`.
- No divergence from upstream unless strictly necessary.
- `UPSTREAM_VERSION` and `UPSTREAM_COMMIT` are changed deliberately, never by
  a bot, because every upgrade must re-verify that the patches still apply and
  the tests pass.
- Dependabot updates only the pinned GitHub Actions.

To upgrade:

1. Update `UPSTREAM_VERSION`.
2. Update `UPSTREAM_COMMIT`. It is the commit the tag points to:
   `git ls-remote https://github.com/dexidp/dex.git 'refs/tags/<tag>^{}'`.
3. Run `./scripts/test.sh` and `./scripts/build.sh`.
4. Refresh the patches if needed.

## CI and releases

- **`ci`** (pull requests, pushes to `main`):
  - prepares the upstream source and runs the tests;
  - builds the image locally;
  - checks `dex version`;
  - runs an informational Trivy scan.
  - It never pushes and uses no registry credentials.
- **`release`** (tags `v*-pathops.*`):
  - validates the tag and re-runs the tests;
  - builds the image locally and scans it before publishing, in a job without
    registry credentials;
  - builds and pushes `docker.io/gborba/pathops-dex:<tag>` with Buildx (BuildKit
    SBOM and provenance included);
  - records the digest;
  - creates a GitHub artifact attestation, also pushed to the registry;
  - scans the published digest in a separate job that has no registry
    credentials.

## Security

- **Vulnerability scan.** Trivy scans every CI build, every release image
  before it is pushed, and every published digest. Findings are reported in the workflow log and summary, but do not
  block. Most findings in this image would be inherited from upstream Dex and
  its base images. Gating is deferred until findings introduced by this
  repository can be separated from inherited ones.
- **Provenance.** Verify a release with:

  ```bash
  gh attestation verify oci://docker.io/gborba/pathops-dex@<digest> --repo PathOps/pathops-dex
  ```

- **Workflow hardening.**
  - Third-party actions are pinned by commit SHA.
  - Workflows default to read-only permissions.
  - The scanner never runs in a job that holds publishing secrets.
- **Reporting.** Security issues in Dex itself should be reported to the Dex
  project. For issues specific to this patch set or its images, use GitHub
  private vulnerability reporting on this repository.

## License

Apache License 2.0, the same license as Dex. See `LICENSE` and `NOTICE`. Images
include the upstream license and a PathOps notice under
`/usr/share/doc/pathops-dex/`.
