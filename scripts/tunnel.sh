#!/usr/bin/env bash
# Opens a Session Manager port-forwarding tunnel through the bastion.
#
#   scripts/tunnel.sh eks   [local-port]   # localhost:8443  -> EKS private endpoint :443
#   scripts/tunnel.sh db    [local-port]   # localhost:15432 -> RDS PostgreSQL     :5432
#   scripts/tunnel.sh cache [local-port]   # localhost:16379 -> ElastiCache Valkey :6379
#
# Endpoints and the bastion ID are read from SSM Parameter Store. ENV and AWS_REGION may be overridden.
# Requires the AWS CLI v2 and the Session Manager plugin. Runs in the foreground; stop with Ctrl-C.

set -euo pipefail

ENV="${ENV:-sandbox}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
PREFIX="/${ENV}/${AWS_REGION}"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

param() {
  local out
  out="$(aws ssm get-parameter --name "$1" --query Parameter.Value --output text 2>&1)" || {
    echo "error: can't read SSM parameter $1 (is the stack that publishes it applied?): $out" >&2
    exit 1
  }
  echo "$out"
}

target="${1:-}"
case "$target" in
  eks)
    host="$(param "${PREFIX}/eks/cluster_endpoint")"
    host="${host#https://}"
    remote_port=443
    local_port="${2:-8443}"
    ;;
  db)
    host="$(param "${PREFIX}/data/db_endpoint")"
    remote_port="$(param "${PREFIX}/data/db_port")"
    local_port="${2:-15432}"
    ;;
  cache)
    host="$(param "${PREFIX}/data/cache_endpoint")"
    remote_port="$(param "${PREFIX}/data/cache_port")"
    local_port="${2:-16379}"
    ;;
  *)
    usage
    ;;
esac

command -v session-manager-plugin >/dev/null || {
  echo "error: the Session Manager plugin is not installed (brew install --cask session-manager-plugin)" >&2
  exit 1
}

bastion="$(param "${PREFIX}/bastion/instance_id")"
status="$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=${bastion}" \
  --query 'InstanceInformationList[0].PingStatus' --output text)"
if [[ "$status" != "Online" ]]; then
  echo "error: bastion ${bastion} is not online in Session Manager (status: ${status}). See README troubleshooting." >&2
  exit 1
fi

echo "Tunnel: localhost:${local_port} -> ${host}:${remote_port} via ${bastion}"
exec aws ssm start-session \
  --target "$bastion" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "host=${host},portNumber=${remote_port},localPortNumber=${local_port}"
