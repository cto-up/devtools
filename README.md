# devtools

Development tooling shared by several application repos that pin the same
`*-fe-lib` frontend libraries. Each consumer pins this repo as a submodule at
`devtools/`, so a fix here reaches every consumer by moving a pointer, the
same way a library fix does.

| File | What it does |
| --- | --- |
| `fe-libs.sh` | Keeps the shared library submodules moving forward in every consumer: `status`, `drift`, `attach`, `work`, `ship`, `publish`, `bump`, `verify`, and `guard` for the pre-commit hook. See its header. |
| `libs.mk` | The `make libs-*` targets that call it. |
| `test-it.sh` | DB-backed tests on a throwaway clone of the local dev database. See its header. |
| `gen-docs-site.py` | Regenerates a consumer's MkDocs stub trees and navs from `docs/`, including pages owned by a library in `docs/platform-docs/libs/`. What each site publishes comes from the consumer's `docs-site/sites.json`. See its header. |
| `docs.mk` | The `make docs-lint` / `docs-stale` / `docs-site-links` targets that call `docs-check.py` and Vale. See its header. |
| `docs-check.py` | Checks for a `docs/` tree: front matter, stale pages, relative and cross-site links, forbidden words, env vars the Go code reads but the docs never name. See its header. |

## Using it in a consumer

```make
FE_LIB_CONSUMERS := app-a app-b app-c   # sibling directories that pin the same libraries
-include devtools/libs.mk

test-it:
	@MIGRATION_ENV=APP_MIGRATION_TEST_DSN PG_CONTAINER=my-postgres ./devtools/test-it.sh
```

Nothing repo-specific lives here: consumer names, DSN variables and container
names come from the consumer.

## Changing it

Edit it inside a consumer, try it there, then ship it like any library:

```bash
make libs-ship LIB=devtools M="what changed" FILES="fe-libs.sh"
```

`ship` pushes this repo first and then moves the `devtools` pointer in every
consumer, forward only.
