# Verdaccio Host

Private npm registry. Single `docker-compose.yaml`. Env-driven. Coolify-ready.
No host bind mounts — uses compose `configs:` (inline yaml) + named volumes.

## Files

```
verdaccio-host/
├── docker-compose.yaml   # everything: service + config + volumes
├── .env.example          # all knobs
└── README.md
```

That's it. No conf/, no Makefile. `docker compose up -d` does it all.

---

## Local

```bash
cp .env.example .env
docker compose up -d
docker compose logs -f
```

UI: http://localhost:4873

Create user (npm CLI):
```bash
npm adduser --registry http://localhost:4873/
```

Or via API:
```bash
curl -X PUT -H "Content-Type: application/json" \
  -d '{"name":"alice","password":"s3cret","email":"a@b.io"}' \
  http://localhost:4873/-/user/org.couchdb.user:alice
```

---

## Coolify deploy

1. **New Resource → Docker Compose** → paste this repo URL (or upload `docker-compose.yaml`).
2. **Environment Variables** tab — set what you need (anything missing falls back to defaults baked into compose):

   ```
   VERDACCIO_PUBLIC_URL=https://npm.tradinx.in
   PRIVATE_SCOPE=@pratikbhadane24
   REGISTRY_TITLE=Tradinx Registry
   MAX_USERS=1000
   TRUST_PROXY=10.0.0.0/8
   ```

   Or use Coolify's auto-domain: set
   ```
   VERDACCIO_PUBLIC_URL=https://$SERVICE_FQDN_VERDACCIO_4873
   ```
   then click **Generate Domain** in Coolify UI.

3. **Domains / Reverse Proxy** — Coolify wires Traefik to port `4873` automatically.
4. **Persistent Storage** — already declared via named volumes (`verdaccio_storage`, `verdaccio_plugins`). Coolify auto-detects + manages backups.
5. **Deploy.**

After first user signup, set `MAX_USERS=-1` in Coolify env, redeploy → signup locked.

---

## Use registry

`.npmrc` in your project:
```
registry=https://npm.tradinx.in/
@pratikbhadane24:registry=https://npm.tradinx.in/
//npm.tradinx.in/:_authToken=YOUR_TOKEN
```

Get token:
```bash
npm login --registry https://npm.tradinx.in/
# or:
npm token create --registry https://npm.tradinx.in/
```

Publish private package:
```bash
npm publish --registry https://npm.tradinx.in/
```

---

## Env knobs

| Var | Default | Purpose |
|-----|---------|---------|
| `VERDACCIO_PORT` | `4873` | Host port |
| `VERDACCIO_PUBLIC_URL` | `http://localhost:4873` | Public URL behind reverse proxy |
| `VERDACCIO_VERSION` | `6` | Image tag |
| `RESTART_POLICY` | `unless-stopped` | Container restart policy |
| `REGISTRY_TITLE` | `Verdaccio` | UI title |
| `REGISTRY_PRIMARY_COLOR` | `#4b5e40` | UI accent |
| `MAX_USERS` | `1000` | `-1` to lock signup |
| `BCRYPT_ROUNDS` | `12` | htpasswd hashing cost |
| `PRIVATE_SCOPE` | `@pratikbhadane24` | Your private npm scope |
| `UPLINK_NPMJS_URL` | `https://registry.npmjs.org/` | Upstream registry |
| `TRUST_PROXY` | `127.0.0.1` | Reverse-proxy IP/range for `X-Forwarded-*` |

---

## Operations

```bash
docker compose up -d            # start
docker compose down             # stop (data preserved in named volumes)
docker compose down -v          # stop + WIPE volumes
docker compose restart          # restart
docker compose logs -f          # tail
docker compose pull && docker compose up -d   # upgrade image
docker compose exec verdaccio sh              # shell
```

---

## Tests

Self-contained e2e suite covering private publish/install, public proxy, catch-all routing, auth, persistence, cache:

```bash
./tests/e2e.sh
```

Spins up an isolated stack on port `14873`, runs 12 checks, tears down. Does not touch your dev/prod stack. See [tests/README.md](tests/README.md).

## Notes

- Compose substitutes `${VAR}` in the embedded `configs.content` at deploy time. Verdaccio's literal `$authenticated` is escaped as `$$authenticated` so compose emits a single `$` to the file.
- Healthcheck uses `127.0.0.1` not `localhost` because alpine resolves `localhost` → `::1` (IPv6) and verdaccio listens IPv4 only.
- Changing config env vars requires `docker compose up -d` to recreate the container (compose rebuilds the config object). Data in named volumes is unaffected.
- All package access is `$authenticated`. Loosen to `$all` in `docker-compose.yaml` `configs.content` for anonymous reads.
- `security.api.legacy: true` keeps compat with older `npm login`. Disable for token-only auth.
