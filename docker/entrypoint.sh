#!/bin/sh
# Entrypoint for the web-ui-dev service in docker-compose.dev.yml.
#
# Seeds the .env files the dev server and API server need, using the exact
# same guard logic as .devcontainer/devcontainer.json's postCreateCommand:
# copy .env-example into place only if the target is missing, never clobber
# a file a developer has already customized with real credentials.
#
#   .devcontainer/devcontainer.json (for reference):
#     { [ -f .env ] || cp .env-example .env; } &&
#     { [ -f .environments/.env.development ] || cp .env-example .environments/.env.development; } &&
#     yarn install
#
# Scope note: this intentionally seeds only the two files the *dev* path
# needs (`.env` for `yarn run start`, `.environments/.env.development` for
# `yarn run dev`/`dev:docker`) -- same scope as the devcontainer. It does not
# seed `.environments/.env.production`; that file backs `yarn run production`
# / a prod-build image, which is out of scope here (see docs/docker-dev.md
# and pr-notes.md for the deferred prod-build-stage follow-up).
#
# Invoked as `sh /usr/src/app/docker/entrypoint.sh <command...>` from
# docker-compose.dev.yml rather than relying on this file's own execute bit,
# because the repo is bind-mounted from the host and a Windows host doesn't
# preserve Unix executable permissions on checkout.
set -e

cd /usr/src/app

[ -f .env ] || cp .env-example .env
[ -f .environments/.env.development ] || cp .env-example .environments/.env.development

exec "$@"
