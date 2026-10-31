# Shared-library targets. A consumer sets FE_LIB_CONSUMERS (its sibling repos
# that pin the same libraries) and includes this file:
#
#   FE_LIB_CONSUMERS := app-a app-b
#   -include devtools/libs.mk

FE_LIBS = FE_LIB_CONSUMERS="$(FE_LIB_CONSUMERS)" ./devtools/fe-libs.sh

libs-status: ## What every consumer pins, and how far behind (add ARGS=--fetch)
	@$(FE_LIBS) status $(ARGS)

libs-attach: ## Put EVERY submodule on its branch, at the commit this repo pins
	@$(FE_LIBS) attach

libs-work: ## Put a submodule on its branch so you can edit and test it here (LIB=name)
	@$(FE_LIBS) work $(LIB)

libs-ship: ## Commit + gate + push a library, bump every consumer (LIB=name M="message" [FILES="a.vue b.ts"] [PUSH=1])
	@FILES="$(FILES)" PUSH="$(PUSH)" $(FE_LIBS) ship $(LIB) "$(M)"

libs-publish: ## Push a submodule's commits to its library, then stage the pointer (LIB=name)
	@$(FE_LIBS) publish $(LIB)

libs-drift: ## Only what is unpushed or uncommitted, in every consumer and Go library (add ARGS=--fetch)
	@$(FE_LIBS) drift $(ARGS)

libs-bump: ## Move THIS repo's submodule pointers to each library's default branch
	@$(FE_LIBS) bump

# Clones only the submodules that are missing: `git submodule update` on one
# already checked out would detach it and discard the branch bump relies on.
submodules-update: ## Clone any missing submodule, then move every pointer to its library's latest
	@git submodule status | awk '/^-/ {print $$2}' | while read -r p; do \
	  git submodule update --init -- "$$p" || exit 1; \
	done
	@$(FE_LIBS) bump

libs-verify: ## Fail if a pointer is not on its library's default branch (CI guard)
	@$(FE_LIBS) verify

.PHONY: libs-status libs-attach libs-work libs-ship libs-publish libs-drift libs-bump submodules-update libs-verify
