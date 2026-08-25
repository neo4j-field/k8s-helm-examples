#!/usr/bin/env bash
#
# Applies every StorageClass in storageclass/.
#
# storageclass/sc-efs-dynamic.yaml has its fileSystemId as a placeholder
# (FILESYSTEM_ID_PLACEHOLDER) since a real EFS filesystem ID from one
# account/cluster won't exist in another. Pass the real filesystem ID as $1
# to apply it too (scripts/startall.sh provisions/finds this ID and passes it
# in automatically); without an argument, sc-efs-dynamic.yaml is skipped.
#
#   ./create_storageclass.sh              # gp3highiops/io2xfs/premiumxfs only
#   ./create_storageclass.sh fs-0123abcd  # + sc-efs-dynamic with that ID
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

EFS_ID="${1:-}"

kubectl apply -f storageclass/gp3HighIOPS.yaml -f storageclass/io2xfs.yaml -f storageclass/premiumxfs.yaml

if [[ -n "${EFS_ID}" ]]; then
  sed "s/FILESYSTEM_ID_PLACEHOLDER/${EFS_ID}/" storageclass/sc-efs-dynamic.yaml | kubectl apply -f -
else
  echo "No EFS filesystem ID given; skipping storageclass/sc-efs-dynamic.yaml." >&2
  echo "Pass one as \$1 to apply it, e.g.: ./create_storageclass.sh fs-0123abcd" >&2
fi
