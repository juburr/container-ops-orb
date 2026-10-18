<div align="center">
  <img align="center" width="250" src="assets/logos/container-ops-orb-256px.png" alt="Container Ops Orb">
  <h1>Container Ops Orb</h1>
  <i>A CircleCI orb that simplifies building, signing, scanning, and publishing container images.</i><br /><br />
</div>

[![CircleCI Build Status](https://circleci.com/gh/juburr/container-ops-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/juburr/container-ops-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/juburr/container-ops-orb.svg)](https://circleci.com/developer/orbs/orb/juburr/container-ops-orb) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/juburr/container-ops-orb/master/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

## Getting Started
The goal of this orb is to share jobs that allow users to easily perform the following operations:
- Create container images using `docker`, or distroless container images using `apko` and `melange`.
- Sign the container images using `cosign`.
- Publish the container images to a container registry such as `ghcr.io`.
- Scan the contents of container images using `syft` to produce SBOMs.
- Scan the container images for vulnerabilities using `grype`.
- Publish the signature and attach SBOMs and/or scan results as attestations.

## Upgrading
The next release renames a command, the executor and several parameters. Update your config as follows:

| Where | Old | New |
|---|---|---|
| command | `docker_archive` | `docker_save` |
| executor | `default` | `machine` |
| `docker_save` | `output_path` | `archive_dir` |
| `docker_load` | `archive_path` | `archive_dir` |
| `build`, `publish`, `scan` jobs | `archive_path` | `archive_dir` |
| `docker_build` | `context` | `build_context` |
| `build` job | `docker_context` | `build_context` |
| `docker_build`, `build` job | `extra_docker_args` | `extra_args` |
| `docker_build`, `build` job | `version` | `image_version` |
| `docker_build`, `build` job | `use_pull_flag` | `pull` |
| `docker_build`, `build` job | `platforms` | `platform` |
| `scan` job | `scan_source` | `image_source` |
| `build` job | `pre_steps` / `post_steps` | `before_build` / `after_build` |
| `publish` job | `pre_steps` / `post_steps` | `before_publish` / `after_publish` |
| `scan` job | `pre_steps` / `post_steps` | `before_scan` / `after_scan` |
| `docker_login` `username` / `password`, jobs' `registry_username` / `registry_password` | default `DOCKER_USERNAME` / `DOCKER_PASSWORD` | default `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` |

The `before_*` and `after_*` steps run at the same points as the old `pre_steps` and `post_steps`; each job's parameter descriptions say exactly where. If your context defines `DOCKER_USERNAME` and `DOCKER_PASSWORD`, rename those variables or pass their names to `username` / `password` or `registry_username` / `registry_password`.

Behavior changes:
- `build_args` and `docker_pull`'s `images` (the `build` job's `pull_base_images`) are split on any whitespace, spaces or newlines. Before, a space-separated list such as `A=1 B=2` reached Docker as a single value.
- `docker_save` (and the `build` job) fail when `persist_to_workspace` is true and `archive_dir` is not `<workspace_root>/images`. The workspace step can persist only that directory. Before, it persisted `<workspace_root>/images` anyway, so the archive was missing from the workspace, or the step failed when that directory did not exist.
- A relative `dockerfile` is checked relative to the working directory, where `docker build -f` looks for it, not relative to the build context. Before, the check also accepted `<build context>/<dockerfile>`, but Docker still read the path relative to the working directory, so the build failed or used a different Dockerfile.
- `extra_args` is no longer run through the shell's `eval`. It is still split like shell words, with quotes, backslashes and `#` comments, and environment variables are still substituted, but nothing else is expanded or run, so a variable's value can no longer run a command. `~` and wildcards reach Docker as written, and so do `$(...)` and backticks inside quotes. Outside quotes, a `$(...)` or backtick fails the step before the build, since it would not run; so do an unmatched quote, a backslash at the very end, and bash's `$'...'` or `$"..."` quoting.
- Error and warning messages start with `ERROR:` or `WARN:` and go to stderr. Before, they went to stdout, a missing `docker` printed `FATAL:`, and a failed pull in `docker_pull` printed `WARNING:`.

## How the Publish Job Works
The `publish` job is **tag-oriented** and **single-platform**. Check that this fits your release process before you rely on it.

### Tag-oriented
`publish` loads the image archive saved by `build`. For each tag (`tag` plus `additional_tags`, or each line of `tags_file`) it runs `docker tag` and `docker push`. Signing, SBOM generation and attestation then refer to the image by tag, as `<registry>/<registry_namespace>/<image>:<tag>`.

- Cosign signs a digest, not a tag. The cosign orb looks up the tag's digest when the signing and attestation steps run. With `crane` on the `PATH` it asks the registry, so if another pipeline moves the tag after this job's push, the job signs that other image. Without `crane` it uses the digest Docker recorded when this job pushed the tag. The verification steps look the tag up in the registry when they run.
- With `tags_file`, only the tags listed in the file are pushed, but signing, SBOM generation and attestation still use the `tag` parameter. If `sign` or `sbom` is enabled, include the `tag` value in the tags file. Otherwise those steps fail because the tag is not in the registry. If an earlier publish left an image under that tag, they sign and inventory that older image instead.
- The job does not record the digest it pushed. A downstream job that needs the digest must look up the tag itself, for example with `crane digest`.

### Single-platform
`publish` is designed and tested for single-platform images:

- `build` runs `docker build`. When `platform` is set, it runs `docker buildx build --platform <platform> --load` instead. With Docker's classic image store, `--load` handles only one platform, so `platform` takes a single target such as `linux/arm64`, not a list.
- `docker save` and `docker load` move that image between jobs, and `docker push` publishes it under each tag.

Multi-platform images (an OCI image index covering several architectures) are not supported. To publish one today, build and push it in your own job, for example with `docker buildx build --platform linux/amd64,linux/arm64 --tag <registry>/<namespace>/<image>:<tag> --push .`. Then sign and attest it with the `cosign` orb directly. Syft scans only one platform of an image index, so generate one SBOM per platform with the `syft` orb, for example by passing each platform's manifest digest (`<registry>/<namespace>/<image>@sha256:...`) as the source.

### Possible future feature: digest-first, multi-arch publishing
This is not available in the orb today. A digest-first publish would build all platforms first, then tag once:

1. Build every platform and push them as a single image index, addressed by digest, with no tags yet.
2. Sign and attest that digest, and generate an SBOM for each platform's manifest.
3. Apply every tag to the digest in the registry in one step without pushing the image again, for example with the `tag_digest` command from `container-tagger-orb`.

Signatures would then never depend on where a tag points, and every tag would carry every platform.
