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
  subcommand). The quick-start command below uses the `docker compose`
  spelling throughout.

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
| `docker-compose.dev.yml` | One service, `web-ui-dev`, running both the webpack dev server (UI, :9001) and the Express API server (:5001) in a single container, over the bind-mounted repo and a named `node_modules` volume. |
| `docker/entrypoint.sh` | Seeds `.env` and `.environments/.env.development` from `.env-example` if they don't already exist -- exact same guard logic as `.devcontainer/devcontainer.json`'s `postCreateCommand`, just as a script instead of an inline `&&` chain. |

## Design notes / choices made

**Why one container running both processes, not two services.** The obvious
translation of the README's "run the dev server and the API server in two
terminal windows" would be two Compose services. That doesn't work here, and
the reason is the dev-server proxy. `webpack.config.js`'s `devServer.proxy`
sends the browser-facing routes (`/`, `/api`, `/namespace`, `/podcast`) to a
hardcoded `http://localhost:5001` -- the Express API server. Two services means
two containers means two network namespaces, so `localhost:5001` inside the
dev-server container resolves to nothing: the initial page load (`/`) and every
`/api/*` call fail through the proxy with a 502/504. (The already-merged #586
devcontainer sidesteps this the same way -- it runs both processes inside one
container, on one shared loopback.) So this runs both in a single container:
`yarn install` once, then `yarn run start` (API) in the background and
`yarn run dev:docker` (dev server) in the foreground. Because they share one
loopback, the proxy's `localhost:5001` target resolves. A single `yarn install`
also means there's no second process writing into the shared `node_modules`
volume concurrently, so no install race to guard against. The tradeoff: the two
servers' logs interleave in one stream, and if the backgrounded API crashes the
container keeps running on the foreground dev server -- both acceptable for a
dev environment.

If you specifically want two separate services/containers, the only way to keep
the hardcoded `localhost:5001` proxy target reachable is to have the API
container share the dev-server container's network namespace
(`network_mode: "service:web-ui-dev"`, with all ports published on
`web-ui-dev`). That's more moving parts for no dev-time benefit over the
single-container form above, so it isn't what ships here.

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
- **Loopback vs `0.0.0.0` (two places).** (1) *Host reachability:* plain
  `docker run -p`/Compose `ports:` publishing forwards into the container's
  own network namespace; a server bound to `127.0.0.1` *inside* the container
  is unreachable from the host regardless of how the port is published.
  `yarn run dev` alone hits this. `yarn run dev:docker` (Marzal's `#524`,
  already merged to `master`) adds `--host=0.0.0.0` and is what this setup
  runs. The Express API server (`node server`) already binds all interfaces
  by default (`app.listen(PORT)` with no host argument), so it needs no
  equivalent flag. (2) *Cross-container reachability:* `webpack.config.js`
  proxies `/`, `/api`, `/namespace`, and `/podcast` to a hardcoded
  `http://localhost:5001`. That `localhost` only resolves to the API server
  if both run on the same loopback -- i.e. the same container. This is why
  both processes run in one container here (see the design note above);
  splitting them across two containers breaks the proxy.
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
authoring machine (Compose YAML validated, the container command string
checked with `sh -n`, Dockerfile reviewed by eye against Hadolint's common
rules, shell script checked with `bash -n`) but **has not been run
end-to-end against a real Docker Engine**. See `pr-notes.md` for the full
verification story and what a reviewer should confirm before merging.
