# arches-flux-base

Shared Kustomize bases for Arches FluxCD deployments. Consumed as a git
submodule by project repos (my-project-fluxcd, quartz-fluxcd).

## Components

### `arches-instance/`

Core Arches deployment unit: HelmRelease, Redis, GeoServer, bootstrap job,
namespace, RBAC. Reference as a Kustomize base from the project overlay.

### `s3-gateway/`

Optional nginx-s3-gateway deployment for proxying media files from a private
S3-compatible object store. Include when the S3 endpoint is not publicly
reachable and django-storages URLs need to route through the cluster.

The project overlay must supply a `s3-gateway-credentials` Secret with
`aws-access-key-id` and `aws-secret-access-key` keys.

### `ingress/gateway-api/`

HTTPRoute templates for Gateway API ingress (HTTP->HTTPS redirect, static
asset routing, media routing via s3-gateway, app routing, ReferenceGrant).

## Usage

Add as a git submodule in the project repo root:

```sh
git submodule add https://github.com/flaxandteal/arches-flux-base.git arches-flux-base
```

Enable submodule recursion in the Flux GitRepository:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: flux-system
spec:
  recurseSubmodules: true
```

Reference from the project's namespace kustomization.yaml:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../../arches-flux-base/arches-instance
  - ../../../arches-flux-base/s3-gateway          # optional: S3 media proxy
  # project-specific:
  - config.yaml
  - image-repository.yaml
  - image-policy.yaml
  - imageautomation.yaml
  - secret-geoserver.enc.yaml
  - secret-s3-gateway.enc.yaml                    # if using s3-gateway
  - secret-redis.enc.yaml
  - values.yaml
secretGenerator:
  - name: values-yaml
    namespace: fat-prj-prd-arches-flax
    files:
      - values.yaml=values.yaml
    options:
      # The HelmRelease refers to this Secret by a fixed name (kustomizeconfig.yaml
      # only rewrites valuesFrom names for ConfigMaps).
      disableNameSuffixHash: true
  - name: geoserver-overlay-secrets             # optional, see "GeoServer users and passwords"
    namespace: fat-prj-prd-arches-flax
    envs:
      - geoserver-overlay-secrets.enc.env
configMapGenerator:
  - name: geoserver-datadir
    namespace: fat-prj-prd-arches-flax
    files:
      - workspace.xml=geoserver/workspaces/my-project/workspace.xml
      # ... project-specific geoserver XML
patches:
  - path: patches/release.yaml
    target:
      kind: HelmRelease
  - path: patches/geoserver-overlay.yaml   # see below
    target:
      kind: Deployment
      name: geoserver
```

Supply variables via `postBuild.substitute` in the Flux Kustomization. Keep secrets
out of them: see "Secrets and Flux substitution" below.

**Leave generator hash suffixes on** (kustomize's default), and turn them off only
per generator where a fixed name is needed, as for `values-yaml` above. With the
suffix on, a change to a generated configMap or Secret gives it a new name, and the
Deployments using it roll. Do not set the global
`generatorOptions.disableNameSuffixHash: true`: a per-generator
`disableNameSuffixHash: false` does not override it, so the geoserver config and
secrets would stop reaching running pods.

## GeoServer config overlay

`arches-instance` seeds a complete GeoServer data dir from the image, removes the
demo `workspaces`, `layergroups` and `gwc-layers`, then copies whatever the project
mounted at `/config-overlay` over the top. It knows no filenames: **the consuming
project owns both the files and where they land.**

The overlay is optional. A project with no geoserver config generates no configMap
and gets a clean boot with an empty catalog, ready to be configured in the admin UI.

ConfigMap keys cannot contain `/`, so the directory layout is expressed with
`items[].path`, which each project supplies by patching the Deployment:

```yaml
# patches/geoserver-overlay.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: geoserver
spec:
  template:
    spec:
      volumes:
        - name: geoserver-config-overlay
          configMap:
            name: geoserver-datadir
            items:
              - key: workspace.xml
                path: workspaces/my-project/workspace.xml
              - key: datastore.xml
                path: workspaces/my-project/my-project-pg/datastore.xml
              - key: users.xml
                path: security/usergroup/default/users.xml
              # ... one entry per file, `path` relative to the data dir root
```

Keeping the source files in the project repo under their real data-dir layout
(`geoserver/workspaces/my-project/workspace.xml`) makes the `items` list mechanical
to write, and lets the same tree be mounted straight into a local GeoServer
container for testing:

```
docker run -v $(pwd)/geoserver:/opt/geoserver_data docker.osgeo.org/geoserver:2.28.0
```

## GeoServer users and passwords

GeoServer users live in the project's overlay, in
`security/usergroup/default/users.xml`, so who has access is versioned and
reviewed like any other config, and the pod stays disposable. Their password
digests do not go in that file: it ends up in an unencrypted configMap. Each digest
lives in a sops-encrypted Secret instead, and `users.xml` refers to it with a
placeholder:

```xml
<user enabled="true" name="admin" password="@@secret:admin@@"/>
<user enabled="true" name="jo@example.org" password="@@secret:jo.example.org@@"/>
```

```sh
# geoserver-overlay-secrets.enc.env (sops-encrypted dotenv, one key per user)
admin=digest1:zsGEMDmXrxhyU0I5T3+7jr183iuJS7XEecQaFEeyEr++TvhBRqZIpj7EkdKwX/3m
jo.example.org=digest1:...
```

Generate the Secret with the `secretGenerator` shown under Usage; Flux decrypts the
file at build time. The project's `.sops.yaml` needs a creation rule whose
`path_regex` matches the file; sops encrypts each value of a dotenv file and leaves
the keys readable. The base mounts it (as optional) and, after `seed-data-dir`, its
`fill-overlay-secrets` init container replaces each `@@secret:KEY@@` in the overlay
files with the value of KEY.

Placeholders work in any overlay file, not only `users.xml`. The rules:

- Keys may use only `-._a-zA-Z0-9`, the characters Kubernetes allows in Secret
  keys, so a username such as `jo@example.org` needs a different key name, e.g.
  `jo.example.org`.
- Values are inserted exactly as they are, so they must already be valid where
  they land: XML-escaped (`&amp;`), and on one line. `digest1` values always are.
- A placeholder with no matching key stops the pod at `fill-overlay-secrets`,
  listing what is unfilled, rather than starting GeoServer with a broken file. A
  project with no placeholders is unaffected.
- Only files that came from the overlay are touched.

Mounting the overlay into a local GeoServer (see above) skips the init containers,
so placeholders stay unfilled and those users cannot log in.

### Why `digest1`

A `digest1:` value is a salted, iterated SHA-256 hash: base64 of a 16-byte salt plus
the hash. The salt travels inside the value and no key is involved, so a digest
made anywhere works in every environment and every pod.

Never commit `crypt1:` or `crypt2:` values. They are encrypted with the instance's
keystore, and each pod here creates a fresh keystore at startup, so nothing can
decrypt them afterwards. Datastore credentials belong in a JNDI resource or a
Kubernetes Secret. `plain:` values are plaintext.

Since the data dir is an emptyDir rebuilt from git on every start, changes made in
the GeoServer admin UI, passwords included, are lost on the next restart.

### Tools

- `tools/geoserver_digest.py`: makes or checks a `digest1:` value offline (Python
  3.8+, standard library only). Its docstring has usage examples.

  ```sh
  python3 arches-flux-base/tools/geoserver_digest.py            # prompts twice
  python3 arches-flux-base/tools/geoserver_digest.py --check 'digest1:...'
  ```

- `tools/check-geoserver-config.sh PATH...`: fails on `crypt1:`, `crypt2:`,
  `plain:` and raw `digest1:` values in committed geoserver config, reporting file,
  line and prefix but never the value. Its header has a recommended pre-commit
  hook; run it in CI as well:

  ```sh
  arches-flux-base/tools/check-geoserver-config.sh clusters/*/*/geoserver
  ```

### Password reset

1. Make the new digest with `geoserver_digest.py`. A user can also run it
   themselves and send only the digest, so nobody else sees their password.
2. Replace the user's value in the sops-encrypted env file and merge the change.
   The Secret's name changes, so Flux rolls the geoserver pod. A new user also
   needs an entry in `users.xml` (and group or role membership).
3. For immediate effect the password can also be set in the admin UI, but git
   stays the source of truth: the UI change is lost on the next restart.

### Secrets and Flux substitution

Do not put secret values, digests included, in `postBuild.substitute` or
`substituteFrom` variables used in geoserver config. Substitution runs after
`kustomize build`, so:

- the substituted values land in the generated configMap, unencrypted;
- the configMap's hash suffix is computed before substitution, so changing the
  value does not change the name, and the pod never picks it up;
- a missing variable becomes an empty string, with no error.

The `@@secret:KEY@@` placeholders avoid all three. For the same reason, scripts in
`arches-instance/scripts/` never use `${...}` shell expansions.

## Spatial views

The bootstrap job grants the GeoServer database role membership of
`arches_spatial_views` — the group role Arches core creates on migrate. Project
spatial views grant to that group role, not to the project's own GeoServer role:

```sql
GRANT SELECT ON public.my_view TO arches_spatial_views;
```

**Why the group role.** The SQL defining the views lives in the project's Arches repo,
which cannot know the GeoServer role name — that comes from a per-deployment secret
(`geoserver-db` / `POSTGRES_USERNAME`) and differs per environment. Granting to the fixed
group role keeps that SQL deployment-agnostic, and matches Arches core, whose trigger
grants the auto-generated `<slug>_<geom>` views to the same role. Each environment
supplies membership once, in the bootstrap job.

Two consequences:

- Recreated views are new objects and inherit no grants, so reissue after every `CREATE`.
- A view calling a `SECURITY DEFINER` helper needs `GRANT EXECUTE` on the function too.
  Postgres checks tables referenced in a view against the view *owner*, but function
  execute against the *invoking* role — so a `SELECT` grant alone yields a view that
  resolves and then fails on first query. Granting both to the group role means one
  membership covers them.

The job waits for the role to appear, since the core migration creating it may run after
the job first fires, and fails at `activeDeadlineSeconds` if it never does.

The job connects as the `postgres` superuser, so the Bitnami postgresql subchart needs
`auth.enablePostgresUser: true` (its default) — that is what writes the `postgres-password`
key the job reads. Note this is *not* the `password` key in the same Secret, which holds the
application user's password. A project running Postgres outside the subchart must supply a
Secret with the `postgres-password` key name.

## Variables

### arches-instance

| Variable              | Example                                   | Description                                                                    |
|-----------------------|-------------------------------------------|--------------------------------------------------------------------------------|
| `NAMESPACE`           | `fat-prj-prd-arches-flax`                 | Kubernetes namespace                                                           |
| `RELEASE_NAME`        | `fat-prj-prd`                             | Helm release name                                                              |
| `CHART_VERSION`       | `0.0.25`                                  | archesproject chart version                                                    |
| `GEOSERVER_VERSION`   | `2.28.0`                                  | GeoServer image tag                                                            |
| `GEOSERVER_PROXY_URL` | `https://geoserver.example.com/geoserver` | GeoServer public base URL                                                      |
| `PG_SUPERUSER_SECRET` | `fat-prj-postgresql`                      | Secret holding the `postgres` superuser password under key `postgres-password` |

### s3-gateway

| Variable          | Example                                      | Description                        |
|-------------------|----------------------------------------------|------------------------------------|
| `NAMESPACE`       | `fat-prj-prd-arches-flax`                    | Kubernetes namespace               |
| `S3_BUCKET_NAME`  | `my-project-media-store-stg`                 | S3 bucket name                     |
| `S3_SERVER`       | `object-storage.nz-hlz-1.catalystcloud.io`   | S3 endpoint hostname (no scheme)   |
| `S3_SERVER_PORT`  | `443`                                        | S3 endpoint port                   |
| `S3_SERVER_PROTO` | `https`                                      | S3 endpoint scheme                 |
| `S3_REGION`       | `us-east-1`                                  | S3 region                          |
| `S3_STYLE`        | `path`                                       | `path` or `virtual` addressing     |

### s3-gateway

| Variable          | Example                                      | Description                        |
|-------------------|----------------------------------------------|------------------------------------|
| `NAMESPACE`       | `fat-prj-prd-arches-flax`                    | Kubernetes namespace               |
| `S3_BUCKET_NAME`  | `my-project-media-store-stg`                 | S3 bucket name                     |
| `S3_SERVER`       | `object-storage.nz-hlz-1.catalystcloud.io`   | S3 endpoint hostname (no scheme)   |
| `S3_SERVER_PORT`  | `443`                                        | S3 endpoint port                   |
| `S3_SERVER_PROTO` | `https`                                      | S3 endpoint scheme                 |
| `S3_REGION`       | `us-east-1`                                  | S3 region                          |
| `S3_STYLE`        | `path`                                       | `path` or `virtual` addressing     |

### ingress/gateway-api

| Variable                | Example                        | Description                           |
|-------------------------|--------------------------------|---------------------------------------|
| `NAMESPACE`             | `fat-prj-prd-arches-flax`      | Backend service namespace             |
| `RELEASE_NAME`          | `fat-prj-prd`                  | Helm release name (for service names) |
| `DOMAIN_NAME`           | `my-project.example.com`       | Site hostname                         |
| `GATEWAY_NAME`          | `my-project-gateway`           | Gateway resource name                 |
| `GATEWAY_HTTP_SECTION`  | `my-project-http`              | Gateway listener for HTTP             |
| `GATEWAY_HTTPS_SECTION` | `my-project-https`             | Gateway listener for HTTPS            |

## What stays in the project repo

- `config.yaml` - image ConfigMaps with `$imagepolicy` setters (ImageUpdateAutomation writes to this)
- `image-repository.yaml`, `image-policy.yaml`, `imageautomation.yaml` - project-specific image registries and tag patterns
- `values.yaml` - SOPS-encrypted Helm values
- `secret-*.enc.yaml` - SOPS-encrypted secrets
- `geoserver-overlay-secrets.enc.env` - SOPS-encrypted values for `@@secret:KEY@@` placeholders, e.g. GeoServer password digests
- `geoserver/` - project-specific workspace XML configs
- `settings-local-configmap.yaml` - project-specific Django overrides
- HelmRelease patches - postRenderers for cloud-specific concerns (workload identity, env injection)
- Project-unique CRDs - CNPG, monitoring, etc.
- Ingress gateway - listener config, TLS cert refs (project-specific)

## Development

`tests/run.sh` runs every test suite and needs only docker. Scripts that run in
GeoServer are tested in the GeoServer image itself; set `GEOSERVER_VERSION` to test
another release. CI (`.github/workflows/tests.yml`) runs the suites against several
GeoServer versions, plus shellcheck.

```sh
tests/run.sh
GEOSERVER_VERSION=3.0.1 tests/run.sh
```
