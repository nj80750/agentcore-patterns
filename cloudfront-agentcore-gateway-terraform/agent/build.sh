#!/usr/bin/env bash
#
# Builds the AgentCore Runtime deployment package.
#
#   cd agent && ./build.sh
#
# Required before `terraform apply` when agent_enabled = true. Terraform reads
# dist/agent.zip, uploads it to S3 and hashes it, so a MISSING zip fails the plan
# with a clear file-not-found — but a STALE zip looks like "no changes". Rebuild
# whenever main.py changes.
#
# WHY THIS IS A SCRIPT AND NOT TERRAFORM
#
# archive_file cannot run a package manager, and it cannot cross-compile. Wrapping
# the build in a null_resource would hide a multi-minute dependency download behind
# a resource that looks instantaneous in the plan. An explicit step is uglier and
# far easier to debug.
#
# REQUIRES: uv  (https://docs.astral.sh/uv/getting-started/installation/)

set -euo pipefail
cd "$(dirname "$0")"

# AgentCore Runtime is arm64-only, and the wheels must be LINUX wheels. An Apple
# Silicon mac is also arm64, so the obvious local build produces a package that
# imports cleanly on your laptop and fails in the cloud with an import error that
# names a .so file.
PYTHON_PLATFORM="aarch64-manylinux2014"

# Must match the `runtime` value in agent.tf. A mismatch produces wheels built for
# the wrong interpreter ABI.
PYTHON_VERSION="3.12"

# Pinned. An unpinned build that resolves a different MCP version on the next run
# is a reproducibility problem, not a convenience one.
DEPS=(
  "mcp==1.29.1"
  "strands-agents==1.53.0"
)

BUILD_DIR="build"
DIST_DIR="dist"
ZIP_PATH="${DIST_DIR}/agent.zip"

echo "==> Cleaning"
rm -rf "${BUILD_DIR}" "${DIST_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

echo "==> Vendoring dependencies for linux/${PYTHON_PLATFORM}, python ${PYTHON_VERSION}"
# --only-binary=:all: is load-bearing. Without it uv will happily fall back to a
# source distribution and build it for the LOCAL platform, producing exactly the
# silent architecture mismatch this script exists to avoid.
uv pip install \
  --target "${BUILD_DIR}" \
  --python-platform "${PYTHON_PLATFORM}" \
  --python-version "${PYTHON_VERSION}" \
  --only-binary=:all: \
  --quiet \
  "${DEPS[@]}"

echo "==> Adding agent source"
cp main.py "${BUILD_DIR}/main.py"

echo "==> Stripping bytecode"
# Bytecode compiled on a different architecture may not be loadable, and it makes
# the zip hash unstable across builds for no benefit.
find "${BUILD_DIR}" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "${BUILD_DIR}" -type f -name '*.pyc' -delete

echo "==> Fixing permissions"
# AgentCore Runtime needs 644 on files and 755 on directories. Without this the
# service may not be able to read them at all.
find "${BUILD_DIR}" -type d -exec chmod 755 {} +
find "${BUILD_DIR}" -type f -exec chmod 644 {} +
if [ -d "${BUILD_DIR}/bin" ]; then
  chmod 755 "${BUILD_DIR}"/bin/* 2>/dev/null || true
fi

echo "==> Zipping"
# -X drops extra file attributes so an unchanged source produces an unchanged hash
# and Terraform stays quiet.
( cd "${BUILD_DIR}" && zip -qrX "../${ZIP_PATH}" . )

echo
echo "    ${ZIP_PATH}"
echo "    zipped   $(du -h "${ZIP_PATH}" | cut -f1 | tr -d ' ')  (limit 250M)"
echo "    unzipped $(du -sh "${BUILD_DIR}" | cut -f1 | tr -d ' ')  (limit 750M)"
echo
echo "==> Done. Now set agent_enabled = true and run terraform apply."
