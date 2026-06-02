#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail "Usage: $0 <source-ref> <checkout-root>"
}

[[ "$#" == "2" ]] || usage

SOURCE_REF="$1"
CHECKOUT_ROOT="$2"

[[ -n "$SOURCE_REF" ]] || fail "source_ref is required"
[[ "$SOURCE_REF" != -* ]] || fail "Signed test build source_ref must not start with '-'"
[[ "$SOURCE_REF" != *$'\n'* && "$SOURCE_REF" != *$'\r'* ]] || fail "Signed test build source_ref must be a single line"
[[ "$SOURCE_REF" != *:* ]] || fail "Signed test builds must use refs from the canonical upstream repository, not fork shorthand refs"
case "$SOURCE_REF" in
    refs/pull/*|pull/*|refs/remotes/*/pull/*)
        fail "Signed test builds must use an upstream branch, tag, or upstream-reachable SHA, not a pull-request ref"
        ;;
esac

[[ -d "$CHECKOUT_ROOT/.git" ]] || fail "Missing git checkout: $CHECKOUT_ROOT"

resolved_commit="$(git -C "$CHECKOUT_ROOT" rev-parse --verify HEAD^{commit})"
[[ "$resolved_commit" =~ ^[0-9a-f]{40}$ ]] || fail "Resolved source commit is not a full SHA: $resolved_commit"

fetch_args=(
    -C "$CHECKOUT_ROOT"
)
server_url="${GITHUB_SERVER_URL:-https://github.com}"
server_url="${server_url%/}/"
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    fetch_args+=(
        -c "http.$server_url.extraheader=AUTHORIZATION: bearer $GITHUB_TOKEN"
    )
elif [[ -n "${GH_TOKEN:-}" ]]; then
    fetch_args+=(
        -c "http.$server_url.extraheader=AUTHORIZATION: bearer $GH_TOKEN"
    )
fi
fetch_args+=(
    fetch
    --prune
    --tags
    origin
    '+refs/heads/*:refs/remotes/origin/*'
    '+refs/tags/*:refs/tags/*'
)

git "${fetch_args[@]}"

containing_refs=()
while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    containing_refs+=("$ref")
done < <(
    git -C "$CHECKOUT_ROOT" for-each-ref \
        --format='%(refname)' \
        --contains "$resolved_commit" \
        refs/remotes/origin refs/tags | \
    grep -Ev '^refs/remotes/origin/(HEAD|pull/)' | \
    sort
)

[[ "${#containing_refs[@]}" -gt 0 ]] || \
    fail "Signed test build commit $resolved_commit is not reachable from any upstream branch or tag in the canonical repository"

reachable_refs="$(IFS=,; printf '%s' "${containing_refs[*]}")"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        printf 'commit=%s\n' "$resolved_commit"
        printf 'reachable_refs=%s\n' "$reachable_refs"
    } >> "$GITHUB_OUTPUT"
fi

printf '%s\n' "$resolved_commit"
