# Vendored marketplace security baseline

The `.mjs` files in this directory are vendored, unmodified copies of the
Omarchy plugin marketplace's **Automated Security Baseline** scanner.

- Source repository: https://github.com/omacom/omarchy-plugin-marketplace
- Source path: `scripts/`
- Vendored from commit: `d5477fdd02f8feb504a681f6f192e55155003007`
- License: MIT — Copyright (c) 2026 HANCORE

Only the dependency-free scanner graph is vendored (no catalog/worker/site
tooling). It is used by `tests/marketplace-baseline-local.mjs` (wired into
`tests/preflight.sh`) to run the exact same deterministic scan the marketplace
runs, but against the local git tree (no push, no network).

These files live under `tests/` because the baseline itself excludes that
directory from the plugin scan — vendored scanner source must never be scanned
as part of the plugin.

To refresh after the marketplace updates its scanner:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/omacom/omarchy-plugin-marketplace.git /tmp/omp
cd /tmp/omp && git sparse-checkout set scripts
# copy the ten scanner files back into tests/marketplace-baseline/ and record
# the new HEAD SHA here.
```

Keep the vendored files unmodified so the local result matches the
marketplace's exactly.
