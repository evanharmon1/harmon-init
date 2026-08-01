# Shared devcontainer image

Harmon Init owns the canonical repository-independent development toolchain at
`images/devcontainer/` and publishes it as:

```text
ghcr.io/evanharmon1/harmon-devcontainer
```

Generated repositories remain separate container instances. They keep their
profiles, Features, mounts, secrets allow-lists, ports, lifecycle commands, and
checked-in `.devcontainer/config/` policy; only the expensive common toolchain
is centralized.

## Artifact contract

Every recommended reference has both human-readable provenance and registry
immutability:

```text
ghcr.io/evanharmon1/harmon-devcontainer:sha-<40-character-source-commit>@sha256:<manifest-digest>
```

The image:

- publishes linux/amd64 and linux/arm64 in one manifest list;
- carries OCI source, revision, version, description, and license labels;
- contains `/usr/local/share/harmon-devcontainer/manifest.json` with its source
  revision, architecture, and important tool versions;
- contains `/usr/local/sbin/install-harmon-repo-config`, the stable contract by
  which a consumer installs its checked-in policy overlay;
- contains no repository checkout, project dependencies, credentials, secrets,
  mounts, ports, or repository-specific config;
- finishes as `root`, ready for an extension layer. A thin consumer explicitly
  returns to `USER vscode` after installing its overlay.

The producer build context is `images/devcontainer/`, whose `.dockerignore`
allows only the Dockerfile and contract helpers. This is the primary control
that prevents unrelated repository contents from entering a layer.

## Validation and publication

`publish-harmon-devcontainer.yml` has three trusted paths:

1. An in-repository pull request builds and smokes the native image and current
   repository overlay, then proves the arm64 producer builds. Fork-controlled
   Dockerfiles are deliberately not executed.
2. A merge to `main` that changes producer inputs publishes the newest commit
   touching those inputs at or before the push head. This remains stable when a
   multi-commit push has an unrelated tail commit. An existing source tag is
   validated and never overwritten.
3. A daily reconciliation applies the same producer-path resolution rule, so an
   interrupted publish or pin sync recovers without selecting a different
   source revision or needing an unsafe branch-selectable `workflow_dispatch`.

GitHub creates a repository's first container package as private. Before the
first run can pass anonymous validation, a repository owner must open the
`harmon-devcontainer` package settings, change its visibility to **Public**, and
rerun the failed publish job (or let the daily reconciliation retry it). The
immutable tag already pushed by that first attempt is validated rather than
overwritten. This is the only visibility bootstrap: the workflow intentionally
does not receive a long-lived personal token or permission to change package
settings, and consumer propagation cannot begin while the package is private.

Publication fails closed unless the manifest digest is valid, both required
architectures exist, the source label and tool manifest match, and each
platform's image can be pulled with an empty Docker credential directory.
Validation pulls each platform by its own child-manifest digest resolved from
the validated index — two platforms pulled through the shared top-level
reference would collide locally on the second pull ("cannot overwrite
digest"). A failed check cannot advance consumers.

## Pin propagation

After publication, `scripts/sync-devcontainer-image.sh` validates the public
manifest and maintains one `bot/sync-harmon-devcontainer` PR. It changes only
the validated `FROM` line in the root and template Dockerfiles, preserving any
identical repository-specific extension commands. It runs the release-title
guard and repository verification, never writes `main`, and never merges.
Commit ancestry prevents a delayed workflow from rolling the open PR back to an
older source image, and a force-with-lease prevents concurrent writers from
overwriting a newer rolling branch. Preparation and all repository verification
finish in a credential-free job. Its one-commit Git bundle crosses to a fresh
publisher runner, which validates the exact parent, changed paths, and pin before
minting the short-lived App token. Mutable installers and verification processes
therefore never share a process namespace with repository-write credentials.

The first image is a deliberate bootstrap exception: consumers keep their
standalone Dockerfile until a public digest exists. The first adoption is a
normal reviewed `fix:` PR that runs the helper's `bootstrap` command together
with the assertion, test, documentation, and Renovate migration. Once that PR
merges, every later publication takes the rolling automated path.

## Local commands

```bash
# Offline manifest/reference/sync tests
task test:devcontainer:image:automation

# Heavy native image + current overlay build (needs a Docker daemon)
task test:devcontainer:image

# Manual recovery, run as two separate processes so verification never shares
# a process tree with an exported write token
task sync:devcontainer-image:prepare \
  SOURCE_SHA=<40-character-commit> \
  MANIFEST_DIGEST=sha256:<64-hex-digest>
task sync:devcontainer-image:publish \
  SOURCE_SHA=<40-character-commit> \
  MANIFEST_DIGEST=sha256:<64-hex-digest>
```

The heavy candidate build is intentionally outside `task ci`, like the existing
dual-profile prebuild workflow: it requires a Docker daemon, multi-architecture
emulation, substantial disk, and registry-backed CI infrastructure. Its offline
contract and automation tests remain inside `task verify`.

## Rollback

A consumer rollback restores the previous reviewed `tag@digest` line. Tags are
never overwritten, so the old reference cannot silently change. Existing local
and runner caches remain usable during a registry outage; clean builders fail
instead of falling back to a floating image.
