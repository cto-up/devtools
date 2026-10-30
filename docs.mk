# Documentation checks, the same in every consumer. A consumer includes it:
#
#   DOCS_ENV_IGNORE := TEST_DATABASE_URL     # env vars deliberately undocumented (test-only)
#   -include devtools/docs.mk
#
# and CI runs `make docs-lint`. The rules behind each check are in
# docs/platform-docs/style/style-guide.md.

DOCS_DIR        ?= docs
DOCS_ENV_DOC    ?= $(DOCS_DIR)/ENVIRONMENT.md
DOCS_CODE_DIR   ?= backend/src
DOCS_ENV_IGNORE ?=
DOCS_STALE_DAYS ?= 180
# platform-docs has its own CI; archive/ is history, kept as it was written.
DOCS_EXCLUDE    ?= --exclude platform-docs --exclude archive
DOCS_CHECK       = python3 devtools/docs-check.py
DOCS_VALE        = vale --config $(DOCS_DIR)/platform-docs/.vale.ini --minAlertLevel error --glob='!**/{platform-docs,archive}/**'

docs-lint: ## Front matter, relative links, env vars, prose errors — what CI checks
	@$(DOCS_CHECK) frontmatter $(DOCS_DIR) $(DOCS_EXCLUDE)
	@$(DOCS_CHECK) links $(DOCS_DIR) $(DOCS_EXCLUDE)
	@$(DOCS_CHECK) env --code $(DOCS_CODE_DIR) --doc $(DOCS_ENV_DOC) $(addprefix --ignore ,$(DOCS_ENV_IGNORE))
	@$(DOCS_VALE) $(DOCS_DIR)

docs-stale: ## Pages not reviewed in DOCS_STALE_DAYS days (report only)
	@$(DOCS_CHECK) stale $(DOCS_DIR) $(DOCS_EXCLUDE) --days $(DOCS_STALE_DAYS)

docs-site-links: ## Cross-site links in the built sites under site/ (after a docs build)
	@$(DOCS_CHECK) site-links site

.PHONY: docs-lint docs-stale docs-site-links
