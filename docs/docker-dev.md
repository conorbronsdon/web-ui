# Plain-Docker dev environment

This covers running web-ui's dev server and API server in plain Docker
(Docker Engine/Desktop + Compose) -- no VS Code or GitHub Codespaces
required. It's the counterpart to `.devcontainer/devcontainer.json` (added
in #586), which only helps VS Code/Codespaces users; this is for anyone
using another editor or a plain terminal. See issue #516 for the full
back-and-forth (node version matrix, the `.env` trio, the `dev:docker`
loopback fix) that this setup is built on.

**Note on where this lives:** this is a separate doc file rather than a
README section because #587 (documenting the Codespaces/dev container setup
in the README) was still open at the time this was written. Once #587
merges, consider folding both the devcontainer and plain-Docker paths into
one "Development environments" section in the README, with this file
either merged in or linked from there -- doing it now would risk merge
conflicts against #587's edits to the same file.

## Prerequisites

- Docker Engine or Docker Desktop with Compose v2 (the `docker compose`
  subcommand, not the standalone `docker-compose` v1 binary -- this file
  uses `depends_on: condition: service_healthy`, which needs Compose v2).

## Quick start

```bash
docker compose -f docker-compose.dev.yml up --build
```

- UI (webpack dev server, hot reload): http://localhost:9001
- API (Express reverse proxy): http://localhost:5001

First run will take a while -- `yarn install` compiles `sharp` from source
inside the container (the same native-module build the merged devcontainer
exercised successfully in a Codespace; see the maintainer's comment on
#516). Subsequent starts are fast since `node_modules` lives in a named
Docker volume (`web-ui-node-modules`), not the bind-mounted repo, so it
survives container restarts.

To stop and remove the containers (leaving the node_modules volume and your
`.env*` files intact):

```bash
docker compose -f docker-compose.dev.yml down
```

To also wipe the installed dependencies (forces a clean `yarn install` next
`up`):

```bash
docker compose -f docker-compose.dev.yml down -v
```

## What's in here

| File | Purpose |
|---|---|
| `Dockerfile.dev` | Node 16.20.2 (exact `.nvmrc` match) + yarn 3.4.1 via Corepack. No source is copied in and no install happens at build time -- see the comments in the file for why. |
| `docker-compose.dev.yml` | Two services, `web-ui-dev` (UI, :9001) and `web-ui-api-dev` (API, :5001), sharing the bind-mounted repo and a named `node_modules` volume. |
| `docker/entrypoint.sh` | Seeds `.env` and `.environments/.env.development` from `.env-example` if they don't already exist -- exact same guard logic as `.devcontainer/devcontainer.json`'s `postCreateCommand`, just as a script instead of an inline `&&` chain. |
| `docker/healthcheck-dev.js` | Lets `web-ui-api-dev` wait for `web-ui-dev` to finish installing and come up, instead of racing it to run `yarn install` against the same shared volume. |

## Design notes / choices made

**Why two services instead of one + `docker compose exec`.** The README's
own "Starting the dev server" instructions already run the dev server and
the API server as two independent long-running processes in two terminal
windows. Two Compose services is the direct translation of that: `docker
compose up` starts both, logs are separable
(`docker compose logs -f web-ui-api-dev`), and one crashing/restarting
doesn't take the other down. `docker compose exec` was the other option in
the original ask, but it has a real precondition problem here: `exec` runs
a second process *inside an already-running container*, which only works
smoothly if that container's foreground process is something you can
attach a second command alongside (e.g. a shell). `web-ui-dev`'s foreground
process is `yarn run dev:docker` (webpack-dev-server), which owns PID 1 --
there's no natural place to `exec` a second long-running server into that
same container without it competing for the terminal/lifecycle with the
dev server. A second service avoids the question entirely.

**Why `web-ui-api-dev` doesn't just run its own `yarn install`.** Both
services mount the *same* named volume at `/usr/src/app/node_modules` (so
neither has to reinstall what the other already has, and both see one
consistent `sharp` native build). If both services' commands started with
`yarn install` and both containers came up at the same time via
`docker compose up`, you'd have two `yarn install` processes writing into
the same volume concurrently -- a real race, not just wasted work,
especially for a native module build like `sharp`. Instead, `web-ui-dev` is
the one that runs `yarn install` (matching the original ask: "command runs
`yarn install` then `yarn run dev:docker`"), and `web-ui-api-dev` has
`depends_on: web-ui-dev: condition: service_healthy` -- it only starts
`yarn run start` once `web-ui-dev`'s healthcheck confirms the dev server is
answering on :9001, which can only be true once `yarn install` already
finished. A third, one-shot "installer-only" service was the other option
considered; the healthcheck-gated approach was picked to keep the compose
file to two services instead of three, at the cost of `web-ui-api-dev`
being unable to start until `web-ui-dev` is fully up (acceptable for a dev
environment).

**Why the entrypoint doesn't seed `.environments/.env.production`.** The
README documents three env files as necessary in principle (`.env`,
`.environments/.env.development`, `.environments/.env.production`), but
this setup only exercises the two dev-path scripts (`yarn run dev`/
`dev:docker` and `yarn run start`), which read `.environments/.env.development`
and `.env` respectively -- never `.environments/.env.production`. Seeding a
file nothing here reads would just be silently-wrong ceremony. This matches
the scope of the already-merged devcontainer's `postCreateCommand`, which
has the same two-file guard and the same gap. A `yarn run production` /
prod-build image (the tagged-build workflow Dave asked about, referenced in
the maintainer's #516 comment) is a reasonable follow-up on top of
`Dockerfile.dev`, but is out of scope for this change.

**Why `entrypoint.sh` is invoked as `sh /path/entrypoint.sh` instead of
relying on its own execute bit.** The repo is bind-mounted from the host,
and this was authored on a Windows host, where Git/NTFS don't reliably
preserve the Unix executable bit on checkout. Invoking it via `sh` sidesteps
that entirely -- it works whether or not the bit survived.

## Known landmines from the issue #516 thread (and how this avoids them)

- **Node version.** `.nvmrc` pins `v16.20.2`. Anything Node >=17 needs
  `NODE_OPTIONS=--openssl-legacy-provider` for webpack 4's OpenSSL 3
  incompatibility -- and that same flag is *rejected* outright on Node 16
  (`--openssl-legacy-provider is not allowed in NODE_OPTIONS`). Pinning the
  image to `node:16.20.2-bullseye` exactly sidesteps the whole
  workaround/rejection dance in either direction.
- **`sharp` native build.** `sharp@0.25.4` is a transitive dependency (via
  the favicons build) and compiles from source on `yarn install`. This is
  slow but was proven to complete cleanly on this same Node 16 base by the
  merged devcontainer's Codespace run (#586) -- not independently verified
  in a real Docker Engine container from this machine (see `pr-notes.md`).
- **Loopback vs `0.0.0.0`.** Plain `docker run -p`/Compose `ports:`
  publishing forwards into the container's own network namespace; a server
  bound to `127.0.0.1` *inside* the container is unreachable from the host
  regardless of how the port is published. `yarn run dev` alone hits this.
  `yarn run dev:docker` (Marzal's `#524`, already merged to `master`) adds
  `--host=0.0.0.0` and is what `web-ui-dev`'s command actually runs.
- **The `.env` file trio.** `yarn run start` (`node server`, via `dotenv`)
  reads `.env` at the repo root; `yarn run dev`/`dev:docker` (via
  `dotenv-webpack` + `webpack.config.js`'s `--env.file`) reads
  `.environments/.env.<file>`. These are two different loading mechanisms
  reading two different files, which is why both need to exist even though
  they're typically identical in a dev setup. `docker/entrypoint.sh` seeds
  both required for this file (see above for why production's third file
  isn't included).

## Verification status

This was authored and validated without a working Docker install on the
authoring machine (Compose YAML validated, Dockerfile reviewed by eye
against Hadolint's common rules, shell script checked with `bash -n`,
`healthcheck-dev.js` checked with `node --check`) but **has not been run
end-to-end against a real Docker Engine**. See `pr-notes.md` for the full
verification story and what a reviewer should confirm before merging.
