// Healthcheck for the web-ui-dev service (docker-compose.dev.yml).
//
// Used so web-ui-api-dev can `depends_on: web-ui-dev: condition:
// service_healthy` instead of racing it to run `yarn install` against the
// same shared node_modules volume -- see the "why two services, and why a
// healthcheck" note in docs/docker-dev.md / pr-notes.md.
//
// Plain `node -e` one-liners get unreadable fast once quoting is involved,
// so this lives in its own file instead of inline in the compose YAML.
// No extra dependencies (curl/wget aren't in the base node:16-bullseye
// image, and installing them would go against keeping Dockerfile.dev
// minimal) -- just Node's built-in http module.
const http = require('http')

const req = http.get({ host: '127.0.0.1', port: 9001, path: '/', timeout: 4000 }, (res) => {
  // Any response at all (including a webpack-dev-server 404 while assets
  // are still compiling) means the server is up and node_modules is
  // populated. We only care that something is listening, not that the
  // build finished.
  process.exit(res.statusCode < 500 ? 0 : 1)
})

req.on('error', () => process.exit(1))
req.on('timeout', () => {
  req.destroy()
  process.exit(1)
})
