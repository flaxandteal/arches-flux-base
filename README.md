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
generatorOptions:
  disableNameSuffixHash: true
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

Supply variables via `postBuild.substitute` in the Flux Kustomization.

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

## Variables

### arches-instance

| Variable              | Example                                   | Description                               |
|-----------------------|-------------------------------------------|-------------------------------------------|
| `NAMESPACE`           | `fat-prj-prd-arches-flax`                 | Kubernetes namespace                      |
| `RELEASE_NAME`        | `fat-prj-prd`                             | Helm release name                         |
| `CHART_VERSION`       | `0.0.25`                                  | archesproject chart version               |
| `GEOSERVER_VERSION`   | `2.28.0`                                  | GeoServer image tag                       |
| `GEOSERVER_PROXY_URL` | `https://geoserver.example.com/geoserver` | GeoServer public base URL                 |
| `PG_SUPERUSER_SECRET` | `arches-pg-superuser`                     | Secret with PostgreSQL superuser password |

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
- `geoserver/` - project-specific workspace XML configs
- `settings-local-configmap.yaml` - project-specific Django overrides
- HelmRelease patches - postRenderers for cloud-specific concerns (workload identity, env injection)
- Project-unique CRDs - CNPG, monitoring, etc.
- Ingress gateway - listener config, TLS cert refs (project-specific)
