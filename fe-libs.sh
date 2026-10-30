#!/usr/bin/env bash
# Keep the shared *-fe-lib submodules moving forward across every consumer.
#
# THE PROBLEM THIS SOLVES. Each library has two working copies: the sibling
# checkout at apps/<name>-fe-lib (where codegen writes) and a submodule inside
# each consumer. Commit in one and the other diverges, and once a consumer is
# far enough behind that a full update looks risky, people start lifting single
# fixes across — which is the cherry-picking we are trying to end.
#
# THE RULE: a library change must be PUSHED before any consumer pins it. Not
# "never edit in a submodule" — you need a consumer's test suite and dev server
# to know whether a change works, and the sibling checkout has neither. Edit
# wherever you can test it; just publish before you pin.
#
# `verify` enforces exactly that and nothing more: every pointer must be an
# ancestor of its library's default branch. A commit that only exists inside one
# consumer fails, because that is the state no other consumer can reach by
# moving a pointer — and copying it across is the cherry-pick.
#
#   ./devtools/fe-libs.sh status         what each consumer pins, and how far behind
#   ./devtools/fe-libs.sh attach         every submodule on its branch, at the pin
#   ./devtools/fe-libs.sh work <lib>     put a submodule on its branch so you can
#                                       edit and TEST it inside this consumer
#   ./devtools/fe-libs.sh ship <lib> <msg>
#                                       commit + gate + push the library, then
#                                       bump and commit the pointer in every
#                                       consumer. FILES="a.vue b.ts" commits only
#                                       those (else only what is staged);
#                                       PUSH=1 also pushes each consumer whose
#                                       unpushed commits are pointer bumps only
#   ./devtools/fe-libs.sh publish [lib]  push submodule commits, then re-pin
#   ./devtools/fe-libs.sh sync           fast-forward every sibling checkout
#   ./devtools/fe-libs.sh bump           move this repo's pointers to the default branch
#   ./devtools/fe-libs.sh verify         CI guard: is every pointer published?
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="$(dirname "$REPO_ROOT")"
# The consumer repos, as sibling directory names. Each consumer sets it in its
# own Makefile; the list is theirs, not this library's.
CONSUMERS="${FE_LIB_CONSUMERS:-}"
need_consumers() {
  [ -n "$CONSUMERS" ] || { echo "set FE_LIB_CONSUMERS (the consumer repos, siblings of this one)" >&2; exit 2; }
}

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

# Submodule paths that look like a shared frontend library, plus this tooling
# itself and the shared docs, so a change there ships and is verified like any
# library.
libs_of() {
  git -C "$1" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null \
    | awk '{print $2}' | grep -E -- '(-fe-lib|^devtools|/platform-docs)$' || true
}

# The library's default branch, from the remote rather than assumed.
default_branch_of() {
  local dir="$1" head
  head="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
  [ -n "$head" ] && { echo "${head#origin/}"; return; }
  git -C "$dir" show-ref --verify --quiet refs/remotes/origin/main && { echo main; return; }
  echo master
}

sibling_of() { echo "$APPS_DIR/$(basename "$1")"; }

# A user-typed library name → its submodule path. Accepts the full name
# (core-fe-lib), the short one (core) and the path (frontend/core-fe-lib),
# because `work` has always taken all of them and a name that gets you into a
# library has to be the name that publishes it. Fails when nothing matches, so
# the caller can say so rather than quietly doing nothing.
resolve_lib() {
  local name="${1%/}" lib hits
  lib="$(libs_of "$REPO_ROOT" | grep -E -- "(^|/)${name}\$" | head -1)"
  [ -n "$lib" ] && { echo "$lib"; return 0; }

  hits="$(libs_of "$REPO_ROOT" | grep -- "$name")"
  if [ -z "$hits" ]; then
    echo "no such library: $name" >&2
    echo "  known: $(known_libs)" >&2
    return 1
  fi
  # "fe-lib" matches every library. Taking the first would publish a library the
  # caller never named, so say which ones and let them choose.
  if [ "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "ambiguous library: $name" >&2
    echo "  matches: $(printf '%s\n' "$hits" | while read -r l; do basename "$l"; done | tr '\n' ' ')" >&2
    return 1
  fi
  printf '%s\n' "$hits"
}

known_libs() { libs_of "$REPO_ROOT" | while read -r l; do basename "$l"; done | tr '\n' ' '; }

# ── attach ────────────────────────────────────────────────────────────────────
# Every submodule on its default branch, at the commit this repo pins.
#
# A submodule is detached by default, so the libraries drift into a mix: the ones
# somebody has edited show `main`, the rest show a bare sha. The mix is not
# neutral — it is why editing a library needed a setup step at all, and why the
# same repo looks different in every clone. Attached everywhere, `ship` works on
# any of them straight away and the editor shows one thing.
#
# Attaching moves no content: the branch is created AT the pinned commit, so the
# working tree and the pointer stay exactly where they were.
attach_at() {
  local dir="$1" branch="$2" target="$3" cur unpushed
  cur="$(git -C "$dir" symbolic-ref -q --short HEAD || true)"

  if [ -n "$cur" ] && [ "$cur" != "$branch" ]; then
    echo "on branch $cur — left alone"; return 1
  fi

  if [ -z "$cur" ]; then
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      # A local branch with commits of its own is somebody's unpublished work.
      # Checking it out would move the tree under them; say so instead.
      unpushed="$(git -C "$dir" rev-list --count "origin/$branch".."$branch" 2>/dev/null || echo 0)"
      if [ "$unpushed" != "0" ]; then
        echo "local $branch has $unpushed unpushed commit(s) — ship or drop them first"; return 1
      fi
      git -C "$dir" checkout --quiet "$branch" || { echo "could not check out $branch"; return 1; }
    else
      git -C "$dir" checkout --quiet -b "$branch" "$target" 2>/dev/null \
        || { echo "could not create $branch"; return 1; }
      git -C "$dir" branch --quiet --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true
    fi
  fi

  if [ "$(git -C "$dir" rev-parse HEAD)" != "$(git -C "$dir" rev-parse "${target}^{commit}")" ]; then
    git -C "$dir" merge --ff-only "$target" >/dev/null 2>&1 \
      || { echo "$branch has diverged from $target — needs a human"; return 1; }
  fi
  return 0
}

# `git submodule update` checks out a detached HEAD and would undo the attach on
# the next pull. merge fast-forwards the branch instead. .gitmodules cannot be
# trusted to carry this (git only reads `update` from there at init time), so
# every attach sets it in this clone's config.
keep_attached() { git -C "$1" config "submodule.$2.update" merge; }

cmd_attach() {
  bold "Putting every submodule on its branch, at the commit $(basename "$REPO_ROOT") pins"
  local moved=0 stuck=0
  for lib in $(libs_of "$REPO_ROOT"); do
    local dir="$REPO_ROOT/$lib" name branch pin was err
    name="$(basename "$lib")"
    if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
      printf '  %-22s not initialised\n' "$name"; continue
    fi
    pin="$(git -C "$REPO_ROOT" ls-tree HEAD "$lib" 2>/dev/null | awk '{print $3}')"
    [ -n "$pin" ] || continue
    branch="$(default_branch_of "$dir")"
    was="$(git -C "$dir" symbolic-ref -q --short HEAD || echo '')"
    if err="$(attach_at "$dir" "$branch" "$pin")"; then
      keep_attached "$REPO_ROOT" "$lib"
      if [ -z "$was" ]; then
        printf '  %-22s attached to %s at %s\n' "$name" "$branch" "${pin:0:8}"
        moved=$((moved + 1))
      else
        printf '  %-22s already on %s\n' "$name" "$was"
      fi
    else
      printf '  %-22s %s\n' "$name" "$err"
      stuck=$((stuck + 1))
    fi
  done
  echo
  if [ "$stuck" -gt 0 ]; then
    dim "$stuck submodule(s) left as they were — see the reason on each line."
  elif [ "$moved" -eq 0 ]; then
    dim "Nothing to do: every submodule was already on its branch."
  else
    dim "No content moved — each branch was created at the commit already pinned."
  fi
  return 0
}

cmd_status() {
  local fetch="${1:-}"
  need_consumers
  bold "Shared frontend libraries — what each consumer pins"
  echo
  printf '%-22s %-10s %s\n' "LIBRARY" "SIBLING" "CONSUMERS (commits behind the library's default branch)"
  for lib in $(libs_of "$REPO_ROOT"); do
    local name sib branch sib_state
    name="$(basename "$lib")"
    sib="$(sibling_of "$lib")"
    if [ ! -d "$sib/.git" ]; then
      printf '%-22s %-10s %s\n' "$name" "absent" "(no sibling checkout)"
      continue
    fi
    [ "$fetch" = "--fetch" ] && git -C "$sib" fetch origin --quiet 2>/dev/null
    branch="$(default_branch_of "$sib")"
    local dirty ahead behind
    dirty="$(git -C "$sib" status --porcelain | wc -l | tr -d ' ')"
    ahead="$(git -C "$sib" rev-list --count "origin/$branch"..HEAD 2>/dev/null || echo 0)"
    behind="$(git -C "$sib" rev-list --count HEAD.."origin/$branch" 2>/dev/null || echo 0)"
    sib_state="ok"
    [ "$behind" != "0" ] && sib_state="-$behind"
    [ "$ahead"  != "0" ] && sib_state="+$ahead${sib_state#ok}"
    [ "$dirty"  != "0" ] && sib_state="$sib_state*"

    local line=""
    for c in $CONSUMERS; do
      local croot="$APPS_DIR/$c" sha n
      [ -d "$croot/.git" ] || continue
      sha="$(git -C "$croot" ls-tree HEAD "$lib" 2>/dev/null | awk '{print $3}')"
      if [ -z "$sha" ]; then line="$line  $c:—"; continue; fi
      n="$(git -C "$sib" rev-list --count "$sha".."origin/$branch" 2>/dev/null)"
      if [ -z "$n" ]; then line="$line  $c:UNKNOWN"
      elif [ "$n" = "0" ]; then line="$line  $c:current"
      else line="$line  $c:-$n"; fi
    done
    printf '%-22s %-10s%s\n' "$name" "$sib_state" "$line"
  done
  echo
  dim "sibling: -n behind · +n unpushed · * uncommitted     consumer: -n commits behind"
  dim "UNKNOWN = the pinned commit is not in the library — see 'verify'."
}

cmd_sync() {
  bold "Fast-forwarding sibling checkouts"
  local blocked=0
  for lib in $(libs_of "$REPO_ROOT"); do
    local sib name branch
    name="$(basename "$lib")"; sib="$(sibling_of "$lib")"
    [ -d "$sib/.git" ] || continue
    git -C "$sib" fetch origin --quiet 2>/dev/null
    branch="$(default_branch_of "$sib")"
    if [ -n "$(git -C "$sib" status --porcelain)" ]; then
      printf '  %-22s SKIPPED — uncommitted changes (yours to resolve)\n' "$name"
      blocked=$((blocked + 1)); continue
    fi
    if git -C "$sib" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
      printf '  %-22s up to date\n' "$name"
    else
      printf '  %-22s DIVERGED — needs a human (rebase or merge)\n' "$name"
      blocked=$((blocked + 1))
    fi
  done
  [ "$blocked" -gt 0 ] && echo && dim "$blocked library(ies) need attention before they can move."
  return 0
}

cmd_bump() {
  bold "Moving $(basename "$REPO_ROOT") submodule pointers to each library's default branch"
  local moved=0 summary=""
  for lib in $(libs_of "$REPO_ROOT"); do
    local dir="$REPO_ROOT/$lib" name branch before after
    name="$(basename "$lib")"
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || { printf '  %-22s not initialised\n' "$name"; continue; }
    git -C "$dir" fetch origin --quiet 2>/dev/null
    branch="$(default_branch_of "$dir")"
    before="$(git -C "$dir" rev-parse HEAD)"
    # On the branch, not detached: one state everywhere, so `ship` works on any
    # submodule without a setup step first. See cmd_attach.
    local err
    if ! err="$(attach_at "$dir" "$branch" "origin/$branch")"; then
      printf '  %-22s %s\n' "$name" "$err"; continue
    fi
    keep_attached "$REPO_ROOT" "$lib"
    after="$(git -C "$dir" rev-parse HEAD)"
    if [ "$before" = "$after" ]; then
      printf '  %-22s already current\n' "$name"
    else
      local n; n="$(git -C "$dir" rev-list --count "$before".."$after" 2>/dev/null || echo '?')"
      printf '  %-22s %s..%s  (+%s)\n' "$name" "${before:0:8}" "${after:0:8}" "$n"
      summary="$summary$name (+$n), "
      moved=$((moved + 1))
    fi
  done
  echo
  if [ "$moved" -eq 0 ]; then
    dim "Nothing moved."
  else
    bold "$moved library(ies) moved. Review, then commit the pointers:"
    echo "    git add $(libs_of "$REPO_ROOT" | tr '\n' ' ')"
    echo "    git commit -m 'Bump frontend libs: ${summary%, }'"
    echo
    dim "Run the frontend test suite before committing — a pointer bump is a"
    dim "dependency upgrade, not a metadata change."
  fi
}

cmd_verify() {
  bold "Verifying $(basename "$REPO_ROOT") pins only published commits"
  local bad=0
  for lib in $(libs_of "$REPO_ROOT"); do
    local dir="$REPO_ROOT/$lib" name sha branch
    name="$(basename "$lib")"
    sha="$(git -C "$REPO_ROOT" ls-tree HEAD "$lib" 2>/dev/null | awk '{print $3}')"
    [ -n "$sha" ] || continue
    if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
      printf '  %-22s not initialised — cannot verify\n' "$name"; continue
    fi
    git -C "$dir" fetch origin --quiet 2>/dev/null
    branch="$(default_branch_of "$dir")"
    if ! git -C "$dir" cat-file -e "$sha^{commit}" 2>/dev/null; then
      printf '  %-22s FAIL — pinned commit %s does not exist in the library\n' "$name" "${sha:0:10}"
      bad=$((bad + 1)); continue
    fi
    if git -C "$dir" merge-base --is-ancestor "$sha" "origin/$branch" 2>/dev/null; then
      printf '  %-22s ok\n' "$name"
    else
      printf '  %-22s FAIL — %s is not on origin/%s (committed in the submodule and never pushed?)\n' \
             "$name" "${sha:0:10}" "$branch"
      bad=$((bad + 1))
    fi
  done
  echo
  if [ "$bad" -gt 0 ]; then
    dim "A pointer off the default branch is how cherry-picking starts: the commit"
    dim "exists in one consumer and nowhere else. Push it to the library, then re-pin."
    return 1
  fi
  dim "Every pointer is an ancestor of its library's default branch."
  return 0
}

# ── work ──────────────────────────────────────────────────────────────────────
# A submodule is normally a detached checkout, so an edit made there cannot be
# committed to a branch and pushed — which is precisely why the old advice was
# "go and edit somewhere else". Put it on its branch instead, and the consumer
# becomes the best place to work: it has the test suite and the running app.
cmd_work() {
  local name="${1:-}"
  [ -n "$name" ] || { echo "usage: $0 work <library>" >&2; return 2; }
  local lib dir branch
  lib="$(resolve_lib "$name")" || return 1
  dir="$REPO_ROOT/$lib"
  git -C "$dir" fetch origin --quiet
  branch="$(default_branch_of "$dir")"

  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    bold "$(basename "$lib") has uncommitted changes — leaving them alone"
  fi
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$dir" checkout --quiet "$branch"
  else
    git -C "$dir" checkout --quiet -b "$branch" --track "origin/$branch"
  fi
  git -C "$dir" merge --ff-only "origin/$branch" >/dev/null 2>&1 || true
  bold "$(basename "$lib") is on $branch at $(git -C "$dir" rev-parse --short HEAD)"
  echo
  echo "  Edit and test it here — this consumer's suite and dev server see the change."
  echo "  When it works:  ./scripts/fe-libs.sh publish $(basename "$lib")"
  echo
  dim "Commit inside $lib as usual. Nothing is shared until publish pushes it."
}

# ── publish ───────────────────────────────────────────────────────────────────
# Push first, THEN pin. The order is the whole guarantee: a pointer is only ever
# committed to a commit every other consumer can already fetch.
cmd_publish() {
  local want="${1:-}" only=""
  local published=0 failed=0
  # Resolve the name up front and REFUSE an unknown one. Skipping every library
  # instead would exit 0 having published nothing, which leaves a pointer that
  # only `verify` catches, in CI, long after you believed you had pushed.
  if [ -n "$want" ]; then
    only="$(resolve_lib "$want")" || return 1
  fi
  bold "Publishing library commits, then re-pinning"
  for lib in $(libs_of "$REPO_ROOT"); do
    local name dir branch ahead
    name="$(basename "$lib")"; dir="$REPO_ROOT/$lib"
    [ -z "$only" ] || [ "$lib" = "$only" ] || continue
    [ -d "$dir/.git" ] || [ -f "$dir/.git" ] || continue
    git -C "$dir" fetch origin --quiet 2>/dev/null
    branch="$(default_branch_of "$dir")"
    ahead="$(git -C "$dir" rev-list --count "origin/$branch"..HEAD 2>/dev/null || echo 0)"
    [ "$ahead" = "0" ] && { [ -n "$want" ] && printf '  %-22s nothing to publish\n' "$name"; continue; }

    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
      printf '  %-22s UNCOMMITTED changes — commit them first\n' "$name"
      failed=$((failed + 1)); continue
    fi
    if ! git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
      printf '  %-22s detached HEAD — run: %s work %s\n' "$name" "$0" "$name"
      failed=$((failed + 1)); continue
    fi
    printf '  %-22s pushing %s commit(s) to origin/%s\n' "$name" "$ahead" "$branch"
    if git -C "$dir" push origin "HEAD:$branch" >/dev/null 2>&1; then
      git -C "$REPO_ROOT" add "$lib"
      printf '  %-22s pushed and staged\n' "$name"
      published=$((published + 1))
    else
      printf '  %-22s PUSH FAILED — the library moved; rebase and retry\n' "$name"
      failed=$((failed + 1))
    fi
  done
  echo
  if [ "$published" -gt 0 ]; then
    bold "$published library(ies) published. Commit the pointer(s) here, then in the other consumers:"
    echo "    make libs-bump   # in each other consumer"
  fi
  [ "$failed" -gt 0 ] && return 1
  return 0
}

# ── ship ──────────────────────────────────────────────────────────────────────
# The whole trip in one command: commit what you just tested, push it to the
# library, and move every consumer onto it.
#
# `work` then `publish` then `bump` in every consumer is five commands and four
# chances to stop halfway — and stopping halfway is exactly the state that ends
# in a cherry-pick. Ship does them in the order that keeps the invariant: the
# library is pushed BEFORE any pointer moves, so every pointer it writes names a
# commit the other consumers can already fetch.
cmd_ship() {
  local name="${1:-}"; shift || true
  local msg="$*"
  if [ -z "$name" ] || [ -z "$msg" ]; then
    echo "usage: $0 ship <library> <commit message>" >&2
    return 2
  fi

  need_consumers
  local lib dir branch
  lib="$(resolve_lib "$name")" || return 1
  name="$(basename "$lib")"
  dir="$REPO_ROOT/$lib"
  if [ ! -d "$dir/.git" ] && [ ! -f "$dir/.git" ]; then
    echo "$name is not initialised in $(basename "$REPO_ROOT")" >&2
    return 1
  fi

  bold "Shipping $name"
  git -C "$dir" fetch origin --quiet 2>/dev/null
  branch="$(default_branch_of "$dir")"

  # Nothing to send? Say so and touch nothing — a no-op must not leave the
  # submodule on a different commit than the one this repo pins.
  local dirty ahead
  dirty="$(git -C "$dir" status --porcelain)"
  ahead="$(git -C "$dir" rev-list --count "origin/$branch"..HEAD 2>/dev/null || echo 0)"
  if [ -z "$dirty" ] && [ "$ahead" = "0" ]; then
    dim "  nothing to ship — $lib is clean and at origin/$branch"
    return 0
  fi

  # 1. Put it on its branch. A submodule is detached by default, and a detached
  #    HEAD cannot be pushed — which is why editing here used to mean a dead end.
  #    Branch from where HEAD actually is; if a stale local branch sits
  #    somewhere else, checking it out would move the tree under the edits.
  if ! git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
    if ! git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$dir" checkout --quiet -b "$branch"
    elif [ "$(git -C "$dir" rev-parse HEAD)" = "$(git -C "$dir" rev-parse "$branch")" ]; then
      git -C "$dir" checkout --quiet "$branch"
    else
      echo "  detached at $(git -C "$dir" rev-parse --short HEAD), but local $branch is at $(git -C "$dir" rev-parse --short "$branch")" >&2
      echo "  reconcile them first:  $0 work $name" >&2
      return 1
    fi
    keep_attached "$REPO_ROOT" "$lib"
    printf '  moved onto %s (was detached)\n' "$branch"
  fi

  # 2. Commit the work — only what the caller named. Several agents share these
  #    checkouts, and `add -A` used to publish whoever else was mid-edit under
  #    this message.
  if [ -n "${FILES:-}" ]; then
    # shellcheck disable=SC2086 # FILES is a space-separated list on purpose
    git -C "$dir" add -- $FILES || { echo "  could not stage FILES in $lib" >&2; return 1; }
  fi
  if ! git -C "$dir" diff --cached --quiet; then
    if ! git -C "$dir" commit --quiet -m "$msg"; then
      echo "  commit failed in $lib" >&2
      return 1
    fi
    printf '  committed %s\n' "$(git -C "$dir" rev-parse --short HEAD)"
  elif [ -n "$dirty" ] && [ "$ahead" = "0" ]; then
    echo "  $lib has changes, but none are named or staged — ship commits only what you say:" >&2
    git -C "$dir" status --short | sed 's/^/      /' >&2
    echo "  re-run with FILES=\"<paths relative to $lib>\", or git add them first" >&2
    return 1
  fi
  [ -n "$(git -C "$dir" status --porcelain)" ] \
    && dim "  left uncommitted (not yours to ship): $(git -C "$dir" status --porcelain | awk '{print $2}' | tr '\n' ' ')"

  ahead="$(git -C "$dir" rev-list --count "origin/$branch"..HEAD 2>/dev/null || echo 0)"
  if [ "$ahead" = "0" ]; then
    dim "  nothing to ship — already at origin/$branch"
    return 0
  fi

  # 3. Gate, in this consumer, before anything is published: a bump is a
  #    dependency upgrade, so the library must not add type errors here or lint
  #    errors in the files it changed. The other consumers' CI covers them.
  gate_in_consumer "$lib" "origin/$branch" || return 1

  # 4. Push. One rebase retry, because the library moving under you while you
  #    worked is normal, not an error. --autostash keeps someone else's
  #    uncommitted edits in place; it stores them by sha, never on the stash stack.
  if ! git -C "$dir" push --quiet origin "HEAD:$branch" 2>/dev/null; then
    printf '  push rejected — rebasing onto origin/%s\n' "$branch"
    if ! git -C "$dir" pull --rebase --autostash --quiet origin "$branch"; then
      echo "  REBASE FAILED — resolve the conflict, then re-run:" >&2
      echo "    cd $dir && git rebase --continue   (or: git rebase --abort)" >&2
      return 1
    fi
    if ! git -C "$dir" push --quiet origin "HEAD:$branch"; then
      echo "  PUSH FAILED — the library moved again; look at $dir, then re-run" >&2
      return 1
    fi
  fi
  local sha short
  sha="$(git -C "$dir" rev-parse HEAD)"
  short="${sha:0:8}"
  printf '  pushed %s commit(s) to origin/%s — now at %s\n' "$ahead" "$branch" "$short"

  # 5. The sibling checkout, so codegen does not write against a stale tree.
  local sib
  sib="$(sibling_of "$lib")"
  if [ -d "$sib/.git" ]; then
    git -C "$sib" fetch origin --quiet 2>/dev/null
    if [ -n "$(git -C "$sib" status --porcelain)" ]; then
      printf '  sibling checkout has uncommitted changes — not moved\n'
    elif git -C "$sib" merge --ff-only "origin/$branch" >/dev/null 2>&1; then
      printf '  sibling checkout fast-forwarded\n'
    else
      printf '  sibling checkout has DIVERGED — needs a human\n'
    fi
  fi

  # 6. Every consumer onto the commit that now exists in the library.
  echo
  bold "Bumping consumers to $short"
  local to_push=""
  for c in $CONSUMERS; do
    local croot="$APPS_DIR/$c" cpath cdir pinned
    if [ ! -d "$croot/.git" ]; then
      printf '  %-6s no checkout at %s\n' "$c" "$croot"; continue
    fi
    cpath="$(libs_of "$croot" | grep -E -- "(^|/)${name}\$" | head -1)"
    if [ -z "$cpath" ]; then
      printf '  %-6s does not use %s\n' "$c" "$name"; continue
    fi
    cdir="$croot/$cpath"
    if [ ! -d "$cdir/.git" ] && [ ! -f "$cdir/.git" ]; then
      printf '  %-6s submodule not initialised — skipped\n' "$c"; continue
    fi
    pinned="$(git -C "$croot" ls-tree HEAD "$cpath" 2>/dev/null | awk '{print $3}')"
    if [ "$pinned" = "$sha" ]; then
      printf '  %-6s already at %s\n' "$c" "$short"; continue
    fi
    # Never clobber work in progress: uncommitted changes there are somebody
    # mid-edit, and a checkout would take them with it. A submodule already AT
    # the commit (the one that just shipped) needs no checkout, only the pointer.
    if [ "$(git -C "$cdir" rev-parse HEAD)" != "$sha" ] && [ -n "$(git -C "$cdir" status --porcelain)" ]; then
      printf '  %-6s UNCOMMITTED changes in %s — left alone\n' "$c" "$cpath"; continue
    fi
    git -C "$cdir" fetch origin --quiet 2>/dev/null
    # Forward only. Two agents shipping the same library race here: the later
    # ship can carry the OLDER commit, and re-pinning it would drop the other's
    # change while `verify` stays green (both commits are on the branch).
    if ! git -C "$cdir" merge-base --is-ancestor "$pinned" "$sha" 2>/dev/null; then
      printf '  %-6s pins %s, which %s is not ahead of — left alone\n' "$c" "${pinned:0:8}" "$short"
      continue
    fi
    local cbranch cerr
    cbranch="$(default_branch_of "$cdir")"
    if ! cerr="$(attach_at "$cdir" "$cbranch" "$sha")"; then
      printf '  %-6s %s\n' "$c" "$cerr"; continue
    fi
    keep_attached "$croot" "$cpath"
    # Path-limited, so a consumer's unrelated work in progress stays out of it.
    if git -C "$croot" commit --quiet -m "Bump $name to $short: $msg" -- "$cpath" 2>/dev/null; then
      printf '  %-6s bumped and committed\n' "$c"
      to_push="$to_push $c"
    else
      printf '  %-6s bumped, but the pointer commit failed — commit %s yourself\n' "$c" "$cpath"
    fi
  done

  echo
  if [ -z "$to_push" ]; then
    dim "No pointer moved."
  elif [ "${PUSH:-}" = "1" ]; then
    bold "Pushing consumers"
    for c in $to_push; do push_pointer_only "$APPS_DIR/$c"; done
  else
    bold "$name is published. The pointer commits are local — push them when the branch is ready:"
    for c in $to_push; do
      echo "    git -C $APPS_DIR/$c push"
    done
  fi
  return 0
}

# Push a consumer only when everything it would send is a library pointer move.
# Anything else unpushed is somebody's work, and publishing it is their call.
push_pointer_only() {
  local croot="$1" c other
  c="$(basename "$croot")"
  if ! git -C "$croot" rev-parse --quiet --verify '@{u}' >/dev/null; then
    printf '  %-6s no upstream for %s — not pushed\n' "$c" "$(git -C "$croot" branch --show-current)"
    return
  fi
  other="$(git -C "$croot" diff --name-only '@{u}..HEAD' | grep -vxF -f <(libs_of "$croot") || true)"
  if [ -n "$other" ]; then
    printf '  %-6s NOT pushed — its unpushed commits also touch: %s\n' "$c" "$(echo "$other" | head -5 | tr '\n' ' ')"
    return
  fi
  if git -C "$croot" push --quiet 2>/dev/null; then
    printf '  %-6s pushed\n' "$c"
  else
    printf '  %-6s PUSH REJECTED — the branch moved; pull it, then: git -C %s push\n' "$c" "$croot"
  fi
}

# Run in the consumer that ships: the type-check ratchet, and ESLint (no --fix)
# on the library files about to be published.
gate_in_consumer() {
  local lib="$1" base="$2" front files
  front="$REPO_ROOT/$(dirname "$lib")"
  grep -q '"type-check:gate"' "$front/package.json" 2>/dev/null \
    || { dim "  gate: no frontend beside $lib — skipped"; return 0; }
  files="$(git -C "$REPO_ROOT/$lib" diff --name-only --diff-filter=d "$base..HEAD" -- '*.vue' '*.ts' \
           | sed "s|^|$(basename "$lib")/|")"
  if [ -n "$files" ]; then
    printf '  gate: eslint on %s file(s)\n' "$(echo "$files" | wc -l | tr -d ' ')"
    # shellcheck disable=SC2086
    if ! (cd "$front" && npx eslint $files); then
      echo "  GATE FAILED — lint. Fix, commit in $lib, re-run ship (nothing was pushed)" >&2
      return 1
    fi
  fi
  printf '  gate: type-check ratchet\n'
  if ! (cd "$front" && npm run --silent type-check:gate); then
    echo "  GATE FAILED — type errors grew. Fix, commit in $lib, re-run ship (nothing was pushed)" >&2
    return 1
  fi
}

case "${1:-status}" in
  status)  shift || true; cmd_status "${1:-}" ;;
  sync)    cmd_sync ;;
  bump)    cmd_bump ;;
  verify)  cmd_verify ;;
  work)    shift; cmd_work "${1:-}" ;;
  publish) shift; cmd_publish "${1:-}" ;;
  ship)    shift; cmd_ship "$@" ;;
  attach)  cmd_attach ;;
  *) echo "usage: $0 {status [--fetch]|attach|work <lib>|ship <lib> <msg>|publish [lib]|sync|bump|verify}" >&2; exit 2 ;;
esac
