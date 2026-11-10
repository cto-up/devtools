# deploy_branch: merge main into an environment branch and start its deploy
# pipeline. A consumer defines _PUSH_FLAGS (the `-o ci.variable="KEY=value"`
# options that pick what ships) and calls it from its deploy targets:
#
#   -include devtools/deploy.mk
#   deploy-preprod-x:
#   	$(call deploy_branch,env-preprod-x,preprod-x)
#
# The merge happens in a throwaway worktree, so the checkout never leaves main
# and a session sharing it is not switched under. The branch is taken local →
# remote → fresh from main; `-u origin $(1)` makes the first deploy of a new
# environment work. A merge that stops leaves its worktree, path printed.
#
# $(2) is the DEPLOY_ENV. On a default deploy (no DEPLOY=) the push also carries
# each component's last deployed commit (scripts/last-deployed.sh), so CI ships
# only what changed since.
#
# A branch already level with main pushes nothing, and GitLab creates no
# pipeline for an empty push: the ci.variable options would be dropped and an
# explicit DEPLOY=observability|firewall|containers|… would do nothing, silently.
# Then the same variables go to a pipeline created through the API (glab, jq).
# A default deploy with nothing new stops there: there is nothing to ship.
define deploy_branch
	git fetch origin --quiet || true
	@if git rev-parse --verify --quiet refs/heads/$(1) >/dev/null; then base=$(1); \
	elif git rev-parse --verify --quiet refs/remotes/origin/$(1) >/dev/null; then base=origin/$(1); \
	else base=main; fi; \
	wt="$$(mktemp -d)/$(1)"; \
	git worktree add --quiet -B $(1) "$$wt" "$$base" || exit 1; \
	git -C "$$wt" merge main --no-edit || { echo "Merge stopped in $$wt: resolve it there, git push -u origin $(1), then git worktree remove $$wt"; exit 1; }; \
	if [ "$$(git -C "$$wt" rev-parse HEAD)" = "$$(git rev-parse --verify --quiet refs/remotes/origin/$(1))" ]; then \
	  git worktree remove --force "$$wt"; \
	  if [ "$(DEPLOY)" = default ]; then echo "$(1) is level with main: nothing new to deploy"; exit 0; fi; \
	  set -- $(_PUSH_FLAGS); \
	  for a; do shift; case "$$a" in ci.variable=*) set -- "$$@" "$${a#ci.variable=}";; esac; done; \
	  body="$$(jq -n --arg ref $(1) '{ref: $$ref, variables: [$$ARGS.positional[] | capture("^(?<key>[^=]+)=(?<value>.*)$$")]}' --args "$$@")" \
	    && out="$$(printf '%s' "$$body" | glab api -X POST "projects/:fullpath/pipeline" -H "Content-Type: application/json" --input -)" \
	    && printf '%s' "$$out" | jq -er '"$(1) is level with main: pipeline \(.id) started through the API, \(.web_url)"' \
	    || { echo "Could not start the pipeline through the API (glab login? jq?)"; exit 1; }; \
	  exit 0; \
	fi; \
	last=""; if [ "$(DEPLOY)" = default ]; then last="$$(sh scripts/last-deployed.sh $(2))"; fi; \
	git -C "$$wt" push -u origin $(1) $(_PUSH_FLAGS) $$last || { echo "Push failed; the merged branch is in $$wt"; exit 1; }; \
	git worktree remove --force "$$wt"
endef
