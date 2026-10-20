#!/usr/bin/env bash
# Terraform CI helpers, used by .github/workflows/terraform-*.yml. Runs on GitHub-hosted runners: needs terraform,
# aws, jq, gh, and the job permission `id-token: write`.
#
#   tf.sh plan  <stack> <plan|apply|drift>   init + plan with the stack's plan role (read-only, -lock=false); writes
#                                            $OUT/<stack>/{plan.txt,changes.json,summary.txt,status}
#   tf.sh apply <stack> <reviewed-dir>       with the stack's apply role: init, plan (locked), compare the resource
#                                            changes with <reviewed-dir>/<stack>/changes.json, apply if they match
#   tf.sh comment <stack> <pr-number>        create or update the PR comment with the stack's plan
#
# Local dry run with your own credentials: TF_CI_SKIP_ASSUME=1 ACCOUNT_ID=<id> scripts/ci/tf.sh plan <stack> plan
#
# status is one of: changes, no-changes, failed, not-deployed (drift: empty state).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$ROOT/.tf-ci}"
ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID is required}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export TF_IN_AUTOMATION=1 TF_INPUT=0

log() { echo "::group::$*"; }
endlog() { echo "::endgroup::"; }

# Exchange this job's GitHub OIDC token for the role's credentials (what aws-actions/configure-aws-credentials does),
# so one job can switch roles per stack. Credentials are masked in the log.
assume() {
  local role="$1" token creds
  # Local dry runs: TF_CI_SKIP_ASSUME=1 uses the current credentials instead.
  if [[ -n "${TF_CI_SKIP_ASSUME:-}" ]]; then echo "TF_CI_SKIP_ASSUME: not assuming ci/${role}"; return 0; fi
  # Explicit checks: callers use `if ! assume ...`, where set -e doesn't apply.
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] || { echo "no GitHub OIDC token: the job needs permission id-token: write"; return 1; }
  token="$(curl -sSf -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com" | jq -er .value)" || { echo "could not get a GitHub OIDC token"; return 1; }
  creds="$(env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN aws sts assume-role-with-web-identity \
    --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/ci/${role}" \
    --role-session-name "gh-${GITHUB_RUN_ID:-local}-${role}" \
    --web-identity-token "$token" --duration-seconds 3600 --query Credentials --output json 2>&1)" \
    || { echo "could not assume ci/${role}: ${creds}"; return 1; }
  AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"$creds")"
  AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"$creds")"
  AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"$creds")"
  echo "::add-mask::$AWS_SECRET_ACCESS_KEY"
  echo "::add-mask::$AWS_SESSION_TOKEN"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  echo "assumed ci/${role}"
}

stack_dir() { echo "$ROOT/$("$HERE/stacks.py" path "$1")"; }

init() {
  local dir="$1"
  # -lockfile=readonly: CI never changes provider pins; a missing or stale .terraform.lock.hcl fails here.
  terraform -chdir="$dir" init -input=false -no-color -lockfile=readonly >/dev/null
}

# The plan's resource and output changes, as a stable list: what the reviewer approved, and what apply compares.
# Reads the plan JSON from a pipe only: it contains sensitive values in clear and is never written to disk.
normalize() {
  jq -S '{
    resources: [.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])
                | {address, actions: .change.actions}] | sort_by(.address),
    outputs: [(.output_changes // {}) | to_entries[] | select(.value.actions != ["no-op"]) | .key] | sort
  }'
}

summary_line() {
  jq -r '"\([.resources[] | select(.actions | index("create"))] | length) to add, \([.resources[] | select(.actions == ["update"])] | length) to change, \([.resources[] | select(.actions | index("delete"))] | length) to destroy" + (if (.outputs | length) > 0 then ", \(.outputs | length) output(s) changed" else "" end)' "$1"
}

cmd_plan() {
  local stack="$1" mode="$2" dir out rc=0
  dir="$(stack_dir "$stack")"
  out="$OUT/$stack"; mkdir -p "$out"
  # Failed until proven otherwise, so the PR comment and reports show a failure at any step.
  echo "failed" >"$out/status"; echo "plan failed (see the run log)" >"$out/summary.txt"
  echo '{"resources":[],"outputs":[]}' >"$out/changes.json"
  if ! assume "tf-${stack}-plan" >"$out/plan.txt" 2>&1; then
    cat "$out/plan.txt"; echo "::error title=$stack::$(tail -1 "$out/plan.txt")"; return 1
  fi
  cat "$out/plan.txt"
  log "init $stack"
  if ! init "$dir" >"$out/plan.txt" 2>&1; then endlog; cat "$out/plan.txt"; echo "::error title=$stack::terraform init failed"; return 1; fi
  endlog

  if [[ "$mode" == drift ]] && [[ -z "$(terraform -chdir="$dir" state list 2>/dev/null)" ]]; then
    echo "not-deployed" >"$out/status"; echo "not deployed (empty state)" >"$out/summary.txt"; : >"$out/plan.txt"
    echo '{"resources":[],"outputs":[]}' >"$out/changes.json"
    echo "$stack: not deployed"; return 0
  fi

  log "plan $stack"
  terraform -chdir="$dir" plan -input=false -no-color -lock=false -detailed-exitcode -out=tfplan >"$out/plan.log" 2>&1 || rc=$?
  endlog
  if [[ $rc -eq 1 ]]; then
    echo "failed" >"$out/status"; echo "plan failed" >"$out/summary.txt"
    cp "$out/plan.log" "$out/plan.txt"; echo '{"resources":[],"outputs":[]}' >"$out/changes.json"
    cat "$out/plan.log"; echo "::error title=$stack::terraform plan failed"
    return 1
  fi
  terraform -chdir="$dir" show -no-color tfplan >"$out/plan.txt"
  terraform -chdir="$dir" show -json tfplan | normalize >"$out/changes.json"
  rm -f "$dir/tfplan"
  if [[ $rc -eq 2 ]]; then
    echo "changes" >"$out/status"; summary_line "$out/changes.json" >"$out/summary.txt"
  else
    echo "no-changes" >"$out/status"; echo "no changes" >"$out/summary.txt"
  fi
  echo "$stack: $(cat "$out/summary.txt")"
}

cmd_apply() {
  local stack="$1" reviewed="$2/$1/changes.json" dir out rc=0
  dir="$(stack_dir "$stack")"
  out="$OUT/apply/$stack"; mkdir -p "$out"
  [[ -f "$reviewed" ]] || { echo "::error title=$stack::no reviewed plan for $stack"; return 1; }
  assume "tf-${stack}" || { echo "::error title=$stack::could not assume ci/tf-${stack}"; return 1; }
  log "init $stack"; init "$dir"; endlog
  log "plan $stack (locked)"
  terraform -chdir="$dir" plan -input=false -no-color -detailed-exitcode -out=tfplan >"$out/plan.log" 2>&1 || rc=$?
  endlog
  if [[ $rc -eq 1 ]]; then cat "$out/plan.log"; echo "::error title=$stack::terraform plan failed"; return 1; fi
  terraform -chdir="$dir" show -json tfplan | normalize >"$out/changes.json"

  # The approval covered the reviewed plan. If anything differs now (state changed meanwhile, or an upstream stack
  # applied earlier in this run changed the outputs this stack reads), stop: re-running the workflow produces a new
  # plan to review.
  if ! diff -u "$reviewed" "$out/changes.json" >"$out/diff.txt"; then
    cat "$out/diff.txt"
    echo "::error title=$stack::the plan changed since it was reviewed (diff above). Re-run the workflow to review the new plan."
    rm -f "$dir/tfplan"; return 1
  fi
  if [[ $rc -eq 0 ]]; then echo "$stack: no changes, nothing to apply"; rm -f "$dir/tfplan"; return 0; fi
  log "apply $stack: $(summary_line "$out/changes.json")"
  terraform -chdir="$dir" apply -input=false -no-color tfplan
  endlog
  rm -f "$dir/tfplan"
}

cmd_comment() {
  local stack="$1" pr="$2" dir="$OUT/$1" marker body id status icon
  marker="<!-- tf-plan:${stack} -->"
  status="$(cat "$dir/status")"
  case "$status" in changes) icon="🟡";; no-changes) icon="🟢";; *) icon="🔴";; esac
  body="$(
    echo "$marker"
    echo "### ${icon} \`${stack}\`: $(cat "$dir/summary.txt")"
    if [[ "$status" != no-changes ]]; then
      echo; echo "<details><summary>Plan</summary>"; echo; echo '```hcl'
      # GitHub comments are limited to 65536 characters.
      head -c 60000 "$dir/plan.txt"; [[ $(wc -c <"$dir/plan.txt") -gt 60000 ]] && echo "... (truncated: see the run log)"
      echo '```'; echo; echo "</details>"
    fi
    echo; echo "<sub>Commit ${GITHUB_SHA:0:7} · [run](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}) · read-only plan role, \`-lock=false\`</sub>"
  )"
  id="$(gh api "repos/${GITHUB_REPOSITORY}/issues/${pr}/comments" --paginate \
    --jq ".[] | select(.body | startswith(\"${marker}\")) | .id" | head -1)"
  if [[ -n "$id" ]]; then
    gh api -X PATCH "repos/${GITHUB_REPOSITORY}/issues/comments/${id}" -f body="$body" >/dev/null
  else
    gh api -X POST "repos/${GITHUB_REPOSITORY}/issues/${pr}/comments" -f body="$body" >/dev/null
  fi
}

case "${1:-}" in
  plan) cmd_plan "${2:?stack}" "${3:-plan}" ;;
  apply) cmd_apply "${2:?stack}" "${3:?reviewed dir}" ;;
  comment) cmd_comment "${2:?stack}" "${3:?pr number}" ;;
  *) sed -n '2,15p' "$0"; exit 2 ;;
esac
