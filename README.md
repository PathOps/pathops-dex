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

## Image

```text
docker.io/gborba/pathops-dex:v2.46.0-pathops.1
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
