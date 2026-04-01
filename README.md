# nuxeo-deployment

Nuxeo LTS deployment built from source code.

## Status

- top-level project scaffold
- `compose.yaml` contract for local PostgreSQL-backed Nuxeo
- `Dockerfile` that builds the Nuxeo server from the public `nuxeo/nuxeo` source tree
- runtime package installation for LibreOffice, Poppler, ImageMagick, Ghostscript, and FFmpeg
  (full FFmpeg with H.264 support via RPM Fusion Free — not the codec-crippled `ffmpeg-free`)
- Nuxeo Web UI built from public `nuxeo/nuxeo-web-ui` source (`lts-2025` branch, pinned to `v2025.13.0`) and pre-installed into the image without requiring a Nuxeo Connect account
- pinned upstream ref in `.env`
- runtime PATH verifier for required conversion binaries
- audit and event system enabled by default (see [Audit and Event Settings](#audit-and-event-settings))
- working event smoke test
- working conversion smoke test with REST-based rendition verification
- consumption patterns documented for `alfresco-content-lake-deploy`
- sample assets directory
- Content Lake facet definitions (`ContentLakeIndexed`, `ContentLakeScope`, `cls:excludeFromScope`)
  deployed into the Nuxeo server config at build time (see [Content Lake Customizations](#content-lake-customizations))
- Nuxeo Web UI custom element for managing folder indexing scope from the browser UI, with smoke
  test for the facet REST API

The current implementation builds the Nuxeo server ZIP from public source and then assembles the
runtime image using the upstream `docker/nuxeo` layout. This is a deliberate adaptation of the
public build flow so `docker compose up --build` can work in this repo without needing a Docker
daemon inside the Docker build itself.

## Layout

```text
nuxeo-deployment/
├── .env.example
├── .gitattributes
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── bug_report.yml
│   │   ├── config.yml
│   │   └── feature_request.yml
│   └── pull_request_template.md
├── .env
├── .gitignore
├── CONTRIBUTING.md
├── Dockerfile
├── LICENSE
├── NOTICE
├── README.md
├── SECURITY.md
├── compose.yaml
├── config/
│   ├── content-lake-facets-contrib.xml   ← Nuxeo component extension: facet definitions
│   └── schema/
│       └── content-lake-scope.xsd        ← XSD schema for the cls: property namespace
├── samples/
│   ├── README.md
│   └── demo-note.txt
├── scripts/
│   ├── check-bootstrap.sh
│   ├── check-runtime-tools.sh
│   ├── smoke-conversion.sh
│   ├── smoke-events.sh
│   └── smoke-facets.sh                   ← verifies ContentLakeIndexed / ContentLakeScope REST API
├── ui/
│   ├── index.jsp                         ← local overlay of the Web UI entrypoint with the custom import hook
│   ├── nuxeo-custom-bundle.html          ← imports the Content Lake folder control after Web UI boots
│   └── content-lake-folder-control.html  ← Polymer element: folder indexing toggles
├── ui-bundle/
│   ├── META-INF/
│   │   └── MANIFEST.MF
│   └── OSGI-INF/
│       └── deployment-fragment.xml       ← unzips the overlay files into nuxeo.war during deployment
```

## Local Contract

- local Nuxeo URL: `http://localhost:8081/nuxeo`
- local REST base: `http://localhost:8081/nuxeo/api/v1`
- local Nuxeo UI: `http://localhost:8081/nuxeo/ui`
- default credentials: `Administrator` / `Administrator`
- database: PostgreSQL

These values are represented in `.env` and `compose.yaml`.

## Pinned Upstream Ref

- tracked public branch: `2025`
- pinned default source ref: `61e3b800592283b4e7d0838baeed38f6218921e3`
- archive URL used by default:
  `https://github.com/nuxeo/nuxeo/archive/61e3b800592283b4e7d0838baeed38f6218921e3.tar.gz`

The SHA above was resolved from the public `nuxeo/nuxeo` branch `2025` on March 25, 2026, then
written into repo-managed config so local builds remain reproducible.

## Build Strategy

The upstream public repository documents the shortcut:

```bash
mvn install -Pdistrib,docker -pl docker/nuxeo -am -DskipTests -Dnuxeo.skip.enforcer=true -T6
```

This repo does not run that exact shortcut inside its `Dockerfile`, because that upstream path uses
Maven's Docker plugin and expects Docker-daemon access during the build.

Instead, this repo:

1. downloads the pinned public source archive
2. runs a Maven `distrib` build to produce `nuxeo-server-tomcat-*.zip`
3. assembles the runtime image with the upstream `docker/nuxeo/rootfs` content and package layout

That keeps the result aligned to the public source tree while preserving the `docker compose up
--build` contract required by issue 11.

## Quick Start

Render the Compose configuration:

```bash
docker compose config
```

Build and start the local stack:

```bash
docker compose up --build
```

The build is substantial. The first run downloads the public Nuxeo source archive, Maven
dependencies, and the runtime packages required by the image.

The default local stack leaves `NUXEO_PACKAGES` empty. This avoids Marketplace installs that
require a registered Nuxeo instance and would otherwise block an unregistered local startup. If you
do have a registered environment and want extra packages, set `NUXEO_PACKAGES` explicitly before
starting the stack.

The runtime image also installs the public OS packages needed for the conversion toolchain:
LibreOffice, Poppler utilities, ImageMagick, Ghostscript, and FFmpeg. On Oracle Linux this uses
the public AppStream/BaseOS repos plus public EPEL and CodeReady Builder metadata.

## Repository Resources

- [LICENSE](LICENSE): Apache License 2.0 for the original contents of this repository
- [NOTICE](NOTICE): attribution notes for the repository and its upstream-assembly model
- [.env.example](.env.example): safe starting point for local overrides and fresh clones
- [CONTRIBUTING.md](CONTRIBUTING.md): contribution and verification expectations
- [SECURITY.md](SECURITY.md): private reporting guidance for security issues

## Configuration

Key values in `.env`:

- `NUXEO_GIT_TRACK`: human-readable upstream line being followed
- `NUXEO_GIT_REF`: exact public source ref to build
- `NUXEO_SOURCE_ARCHIVE_URL`: pinned archive URL used by the Docker build
- `NUXEO_PLATFORM`: defaults to `linux/amd64` for predictable local behavior
- `POSTGRES_IMAGE`: defaults to `postgres:16-alpine`
- `NUXEO_PACKAGES`: empty by default — Nuxeo Web UI is pre-installed into the image at build time and does not need to be listed here
- `NUXEO_WEBUI_GIT_REF`: exact public source ref of `nuxeo/nuxeo-web-ui` used for the web UI build
- `NUXEO_WEBUI_VERSION`: version string used to locate the Maven output zip (must match the ref above)

## Consuming This Image

The image built by this project (`nuxeo-deployment:nuxeo-local`) can be used in two modes by
downstream projects such as `alfresco-content-lake-deploy`.

### Local / Manual Mode

Run this project's stack standalone to get a Nuxeo instance accessible on the host:

```bash
# In nuxeo-deployment/
docker compose up --build
```

Then point any client or connector at the local instance using the values from `.env`:

- Base URL: `http://localhost:8081/nuxeo`
- REST API: `http://localhost:8081/nuxeo/api/v1`
- UI: `http://localhost:8081/nuxeo/ui`
- Credentials: `Administrator` / `Administrator`

This mode is suitable for iterative development, manual testing, and running the smoke tests
without the full downstream stack.

### Container Network Mode

When `alfresco-content-lake-deploy` (or any other project with its own `compose.yaml`) needs to
include Nuxeo as a service, reference the pre-built image directly instead of using `nuxeo:latest`:

```yaml
services:
  nuxeo:
    image: nuxeo-deployment:nuxeo-local
    ...
```

The image tag `nuxeo-deployment:nuxeo-local` is what `docker compose build` in this project writes
to the local Docker daemon (see `NUXEO_IMAGE_NAME` in `.env` and the `image:` key in
`compose.yaml`). The consuming project must run `docker compose build` in `nuxeo-deployment/`
first, or have the image available via a registry pull.

Within the shared Docker Compose network the service is reachable at `http://nuxeo:8080/nuxeo`.

## Content Lake Customizations

This deployment extends a stock Nuxeo server with two layers of customization for the Content Lake
indexing pipeline.

### Content model — `config/`

`config/content-lake-facets-contrib.xml` registers two custom facets via the
`org.nuxeo.ecm.core.schema.TypeService` extension point:

| Facet | Type | Purpose |
|---|---|---|
| `ContentLakeIndexed` | Marker (no schema) | Presence on a folder marks its entire subtree as in-scope for Content Lake ingestion |
| `ContentLakeScope` | Schema-bearing | Carries the `contentLakeScope` schema (prefix `cls`); used to exclude a subtree |

`config/schema/content-lake-scope.xsd` defines the single property in that schema:

| Property | Type | Default | Meaning |
|---|---|---|---|
| `cls:excludeFromScope` | `xs:boolean` | `false` | When `true`, the folder and all descendants are excluded from ingestion even if an ancestor has `ContentLakeIndexed` |

Both XML files and the schema directory are copied into `${NUXEO_HOME}/nxserver/config/` at
Docker build time so they are available on every startup without a Marketplace package or Connect
account.

The `NuxeoScopeResolver` in `content-lake-app` reads these facets at runtime to decide which
documents enter the ingestion pipeline. `NuxeoAuditListener` (nuxeo-live-ingester) invalidates
the scope cache and triggers subtree re-evaluation whenever a folder carrying either facet receives
a `documentModified` audit event.

### Web UI — `ui/`

This Web UI build does not expose a standalone `nuxeo-web-ui-bundle.html` on disk before the
server deploys bundles, so local customizations are packaged as a small overlay bundle instead of a
container-startup patch.

`ui/index.jsp` is a repo-managed overlay of the upstream Web UI entrypoint. It adds a small
post-boot import hook so `ui/nuxeo-custom-bundle.html` loads only after the main Web UI bundle has
initialized. The custom bundle then imports `content-lake-folder-control.html`.

`ui/content-lake-folder-control.html` is a Polymer 3 custom element that contributes a panel to
the `DOCUMENT_ACTIONS` slot in the document toolbar. It renders only on documents that have the
`Folderish` facet (Folder, Workspace) and provides:

| Toggle | Facet change | Condition |
|---|---|---|
| **Index in Content Lake** | Adds / removes `ContentLakeIndexed` | Always shown on folderish documents |
| **Exclude from Content Lake** | Adds / removes `ContentLakeScope` + sets `cls:excludeFromScope` | Shown only when `ContentLakeIndexed` is already set on this folder |

Both toggles are disabled while a request is in flight (a `saving` flag mirrors the Alfresco ACA
`ContentLakeSidebarComponent` pattern). Facet changes use a GET-then-PUT strategy to preserve any
pre-existing mixin facets on the document, matching the Alfresco `copyAspectNames` approach.

The Dockerfile assembles `ui-bundle/` into a small jar and copies it to
`${NUXEO_HOME}/nxserver/bundles/`. On startup, its `deployment-fragment.xml` overlays
`index.jsp`, `nuxeo-custom-bundle.html`, and `content-lake-folder-control.html` into
`nuxeo.war/ui/`. That keeps the customization aligned with the bundle deployment lifecycle while
ensuring the Content Lake slot contribution is loaded on authenticated Web UI sessions.

## Audit and Event Settings

The `nuxeo.stream.audit.enabled` and `audit.elasticsearch.enabled` overrides that appeared in the
old `alfresco-content-lake-deploy/compose.nuxeo.yaml` are not carried into this project.

- `nuxeo.stream.audit.enabled` defaults to `true`. Disabling it would prevent `smoke-events.sh`
  from finding `documentCreated` / `documentModified` entries in the Nuxeo audit log.
- `audit.elasticsearch.enabled` defaults to `false` when no Elasticsearch is configured. Nuxeo
  falls back to its internal audit store (backed by PostgreSQL in this deployment), so no override
  is needed.

The old overrides were a workaround for the `nuxeo:latest` setup in the combined stack. They are
not required here and have been intentionally omitted.

## Scripts

- `scripts/check-bootstrap.sh` verifies that the scaffold and pinned source-build contract are
  present.
- `scripts/check-runtime-tools.sh` fails if the required conversion binaries are not on `PATH`.
- `scripts/smoke-events.sh` creates and updates a live `Note` document, then verifies that
  `documentCreated` and `documentModified` are present in Nuxeo audit for that exact UUID.
- `scripts/smoke-conversion.sh` creates a live Office document, uploads an `.odt`, verifies
  `Blob.ToPDF`, and then probes the FFmpeg-backed video path by uploading a tiny generated MP4 and
  polling `GET /api/v1/id/{uid}?schemas=vid` until `vid:transcodedVideos` is populated (2-minute
  timeout).
- `scripts/smoke-facets.sh` creates a temporary Workspace folder, applies `ContentLakeIndexed` via
  `PUT /api/v1/id/{uid}`, verifies the facet is returned in a subsequent GET, then applies
  `ContentLakeScope` with `cls:excludeFromScope: true` and verifies both, then trashes the folder.

Run the bootstrap check with:

```bash
./scripts/check-bootstrap.sh
```

Verify the required runtime binaries after the stack is running with:

```bash
./scripts/check-runtime-tools.sh
```

Run the event smoke test with:

```bash
./scripts/smoke-events.sh
```

Run the conversion smoke test with:

```bash
./scripts/smoke-conversion.sh
```

Run the Content Lake facets smoke test with:

```bash
./scripts/smoke-facets.sh
```
