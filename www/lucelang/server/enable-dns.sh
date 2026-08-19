#!/bin/sh
# Publish the lucelang.org A records through Route 53, using the AWS CLI.
set -e

here=$(CDPATH= cd "$(dirname "$0")" && pwd)
zone=${LUCELANG_HOSTED_ZONE:-Z092724122WZ9W31AJFPZ}
address=${LUCIAOS_EDGE_ADDRESS:-35.153.110.211}
change_file=$(mktemp "${TMPDIR:-/tmp}/lucelang-route53.XXXXXX")
trap 'rm -f "$change_file"' EXIT HUP INT TERM

sed "s/@ADDRESS@/$address/g" "$here/route53-change.json" > "$change_file"
echo "==> Route 53: lucelang.org -> $address"
change=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "$zone" \
    --change-batch "file://$change_file" \
    --query 'ChangeInfo.Id' \
    --output text)
aws route53 wait resource-record-sets-changed --id "$change"
echo "==> Route 53 change is INSYNC: $change"

