# PR notes — plain-Docker dev environment (issue #516)

Status: **drafted locally, not opened as a PR.** No fork push, no PR, no
issue comment has been made. This file is prep for Conor to review and
decide whether/when to open it.

## Plain-English description

Issue #516 started as "what Node version should I use to dev this locally"
and turned into a long thread of failed attempts across Node 20/22/24/25,
ending with Node 16 (matching `.nvmrc`) being the only version that didn't
need workarounds. #586 (merged) added a VS Code / Codespaces devcontainer
that solves this for VS Code users. Conor's July 8 comment on the issue
proposed the remaining gap: a plain-Docker setup for anyone not using VS
Code, built around three pieces:

- `Dockerfile.dev` on `node:16-bullseye` (no OpenSSL workaround needed)
- `docker-compose.dev.yml` with the repo bind-mounted, env files seeded from
  `.env-example`, ports 9001/5001
- the dev server running via `#524`'s `dev:docker` script (needed because
  a server bound to loopback inside a container is unreachable from the
  host no matter how the port is published)

This PR is that setup, built out with two decisions the original comment
left open:

1. **Node tag precision** — `node:16.20.2-bullseye` (confirmed to exist on
   Docker Hub) instead of the floating `node:16-bullseye`, so the pin can't
   silently drift to a different 16.x patch later.
2. **How `yarn start` (the API server) runs** — as a second Compose
   service (`web-ui-api-dev`) rather than `docker compose exec`, gated on a
   healthcheck so it doesn't race `web-ui-dev`'s `yarn install` against the
   same shared `node_modules` volume. Full reasoning in
   `docs/docker-dev.md`.

Docs live at `docs/docker-dev.md` rather than in the README, because #587
(README documentation for the Codespaces/devcontainer setup) is still open
— editing the README on this branch too would risk a merge conflict against
whatever #587 lands. `docs/docker-dev.md` says as much and flags folding
the two together once #587 merges.

## Files changed

```
 .gitattributes            |   7 +++
 Dockerfile.dev            |  50 +++++++++++++++
 docker-compose.dev.yml    |  88 ++++++++++++++++++++++++++
 docker/entrypoint.sh      |  32 ++++++++++
 docker/healthcheck-dev.js |  27 ++++++++
 docs/docker-dev.md        | 155 ++++++++++++++++++++++++++++++++++++++++++++++
 6 files changed, 359 insertions(+)
```

(`.gitattributes` is new to the repo — added to force LF line endings on
`*.sh` files. `docker/entrypoint.sh` is bind-mounted straight from a
checkout into a Linux container and run via `sh`; if it were ever checked
out with CRLF — the default on many Windows git installs with
`core.autocrlf=true` — the embedded `\r` characters would break it. Caught
this because the repo has no existing `.gitattributes` and this machine's
git config does convert LF→CRLF on touch, confirmed via `git add` warnings
during this work.)

## Proposed PR title

`Add plain-Docker dev environment (Dockerfile.dev + docker-compose.dev.yml)`

## Proposed PR body

> Closes the remaining half of #516: a plain-Docker dev setup for anyone
> not using VS Code / Codespaces (which #586 already covers).
>
> - `Dockerfile.dev`: `node:16.20.2-bullseye` (exact `.nvmrc` match, so no
>   `--openssl-legacy-provider` workaround needed), yarn 3.4.1 via Corepack.
>   No source copied in / no install at build time — the repo is
>   bind-mounted at runtime and `node_modules` lives in its own named
>   volume, so a host `node_modules` (if one exists, and if it's even built
>   for the right OS/arch) never collides with the container's build —
>   including `sharp`, which compiles from source.
> - `docker-compose.dev.yml`: two services sharing that bind mount + volume
>   — `web-ui-dev` (`yarn install && yarn run dev:docker`, port 9001,
>   using @Marzal's `#524` script so the dev server is actually reachable
>   from the host) and `web-ui-api-dev` (`yarn run start`, port 5001,
>   gated on `web-ui-dev`'s healthcheck rather than running its own
>   `yarn install` concurrently against the same volume). Reasoning for
>   both the two-service split and the healthcheck gating is in
>   `docs/docker-dev.md`.
> - `docker/entrypoint.sh`: seeds `.env` and
>   `.environments/.env.development` from `.env-example` if missing —
>   exactly the same guard as `.devcontainer/devcontainer.json`'s
>   `postCreateCommand` (credit to that setup for the pattern), same scope
>   (doesn't seed `.environments/.env.production` — out of scope here, see
>   docs).
> - `docs/docker-dev.md`: usage + the design decisions above. Not a README
>   section because #587 (README docs for the devcontainer) is still open;
>   noted the merge-order consideration in the doc itself.
>
> Thanks to @Marzal for all the version-matrix legwork in this issue (the
> `node:16` vs `20` vs `22`/`24`/`25` attempts and the loopback/`0.0.0.0`
> fix in #524) — this builds directly on that.
>
> **Verification:** built and validated as far as possible without a
> working Docker install on the authoring machine — see the Verification
> section below. **This has not been run against a real Docker Engine.**
> Recommend a maintainer (or Conor, on a machine with Docker) runs:
> ```
> docker compose -f docker-compose.dev.yml up --build
> ```
> and confirms both http://localhost:9001 and http://localhost:5001 come up
> before merging.

## Verification story (honest version)

Docker Desktop/Engine is **not installed** on the machine this was built
on (confirmed before starting). What was and wasn't checked:

**Checked:**
- `docker-compose.dev.yml` parses as valid YAML (`python -c "import yaml;
  yaml.safe_load(open('docker-compose.dev.yml'))"` — succeeds, and the
  parsed structure matches what was intended: two services, correct
  `depends_on`/`condition`/`healthcheck` shape, one top-level volume).
- `docker/entrypoint.sh` passes `bash -n` (syntax only — cannot execute it
  without a container, so the actual `.env` guard behavior at runtime is
  unverified beyond code inspection).
- `docker/healthcheck-dev.js` passes `node --check` (syntax only, same
  caveat — the actual HTTP probe against a running dev server is
  unverified).
- `Dockerfile.dev` reviewed by eye against common Hadolint rules: explicit
  version pin (not `latest`), exec-form `CMD`, no `ADD`, no unnecessary
  layers, no unpinned `apt-get` (none used at all). One thing Hadolint
  would likely flag and that's being accepted deliberately: no `USER`
  directive, so the container runs as root — matches the plain node
  image's default and the "keep it minimal" brief; this is a dev-only
  image, not something pushed to a registry or run in production.
- `node:16.20.2-bullseye` confirmed to exist as a real Docker Hub tag
  (checked via the Docker Hub API), not assumed.
- Cross-checked every design choice against the issue #516 thread's known
  landmines: Node version/OpenSSL, `sharp` native build, loopback binding,
  the `.env` file trio — see the "Known landmines" section in
  `docs/docker-dev.md` for how each is addressed.
- Confirmed `#587` is still open (README doc PR) — that's why docs went to
  `docs/docker-dev.md` instead of README.
- Confirmed `#524` (`dev:docker` script) and `#586` (devcontainer) are both
  already merged to `master`, and read the actual merged
  `.devcontainer/devcontainer.json` on `master` to copy its env-seeding
  guard logic exactly rather than reconstructing it from memory of the
  thread.

**Not checked / cannot check without Docker:**
- Whether `docker compose -f docker-compose.dev.yml up --build` actually
  builds and starts.
- Whether `yarn install` (and specifically the `sharp` native build)
  completes successfully inside `node:16.20.2-bullseye` on this machine's
  architecture. The maintainer's #516 comment notes this same native-module
  build was exercised successfully in a real Codespace as part of #586 —
  that's a different execution environment (Codespaces' underlying
  container host) than a local Docker Engine, so it's supporting evidence,
  not proof, for this Dockerfile.
- Whether the `web-ui-dev` healthcheck actually flips to healthy in
  practice, and therefore whether `web-ui-api-dev`'s `depends_on` gate
  behaves as designed rather than hanging.
- Whether port publishing on the target host (particularly Windows/Docker
  Desktop, since that's the authoring environment) behaves as expected for
  both 9001 and 5001 simultaneously.

**Bottom line: UNTESTED IN REAL DOCKER.** Everything above is static
validation and design review, not a live run. Before merging, either a
maintainer or Conor (on a machine with Docker installed) should run
`docker compose -f docker-compose.dev.yml up --build` and confirm both
http://localhost:9001 (UI) and http://localhost:5001 (API) respond.
