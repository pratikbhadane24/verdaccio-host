# E2E Tests

End-to-end test for the Verdaccio host. Covers the three package routing rules
(private scope, scoped public proxy, catch-all proxy) plus auth, persistence,
and cache behavior.

## Run

```bash
./tests/e2e.sh
```

Spins up an isolated docker compose project (`verdaccio-e2e`) on port `14873`,
runs all 12 tests, tears down. Will not touch your dev/prod stack.

### Flags

| Env var | Effect |
|---------|--------|
| `KEEP_STACK=1` | Leave stack running after tests for manual inspection |
| `REUSE_STACK=1` | Skip recreate; run against existing isolated stack |
| `E2E_PORT=N` | Use a different port (default `14873`) |

```bash
KEEP_STACK=1 ./tests/e2e.sh
# Inspect at http://localhost:14873 then:
docker compose -p verdaccio-e2e down -v
```

## Coverage

| # | Test | What it proves |
|---|------|----------------|
| T1 | `/-/ping` | service alive |
| T2 | unauth GET → 401/403 | `$authenticated` enforced |
| T3 | REST signup → JWT | user creation + token issuance |
| T4 | bcrypt entry in htpasswd | algorithm + rounds applied |
| T5 | install `lodash@4.17.21` | catch-all `**` proxies npmjs |
| T6 | install `@types/node@20.0.0` | `@*/*` rule proxies scoped public |
| T7 | publish `@pratikbhadane24/e2e-fixture@0.0.1` | private scope publish path |
| T8 | install private pkg in fresh consumer | private metadata + tarball serve |
| T9 | publish `0.0.2` | version bump path |
| T10 | re-publish `0.0.2` rejected | immutability of published versions |
| T11 | restart container | named volume persistence |
| T12 | cached lodash on disk | uplink cache writes to storage |

## Fixtures

`tests/fixtures/private-pkg/` — minimal `@pratikbhadane24/e2e-fixture` package.
Bumped via `npm version` during the run; not committed back.

## CI

Add to GitHub Actions:

```yaml
- uses: docker/setup-buildx-action@v3
- run: ./tests/e2e.sh
```

Tests are self-contained: no fixtures pulled from network beyond `lodash` and
`@types/node` (proxied through verdaccio so they hit npmjs once, then cache).
