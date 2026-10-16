#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CACHE_DIR=${SCRIPT_DIR}/.buildx-cache

# The image name and the tool versions come from the same file the VM and the
# bare-metal setup use, so the image and the VM install the same things.
# Override PROVERS_IMAGE to build and push somewhere else.
# shellcheck source=../bin/versions.sh
source "${SCRIPT_DIR}/../bin/versions.sh"

IMAGE=${PROVERS_IMAGE}

# The tag suffix, pinned in versions.sh rather than taken from today's clock, so
# that the container and the VM built from the same pins carry the same version
# -- and so that a rebuild meant to replace a published build tags over it rather
# than beside it.  PROVERS_BUILD_VER=$(date +%Y.%m.%d) for a new one.
VERSION=${PROVERS_BUILD_VER}

# Only the architecture-independent pins are forwarded.  versions.sh also derives
# per-architecture values, but from the *host's* uname, which would be wrong for
# whichever of the two images is cross-built; inside the image the same file is
# sourced again and derives them from the target's uname instead.
BUILD_ARGS=()
for v in MICROKIT_SDK_VER RUST_TOOLCHAIN_VER \
         SDFGEN_VER VERUS_VER Z3_VER LIONSOS_VER \
         SIREUM_V SIREUM_INIT_V PROVERS_BUILD_VER; do
  BUILD_ARGS+=(--build-arg "${v}=${!v}")
done

# One Dockerfile for both architectures -- the install scripts it runs resolve
# every per-architecture difference themselves.  The build context is provers-env,
# the parent of this directory, so that bin/ is reachable from it.
DOCKERFILE=${SCRIPT_DIR}/Dockerfile.provers
CONTEXT=${SCRIPT_DIR}/..

# Exporting the layer cache to disk is opt-in.  'mode=max' writes every layer of
# every stage on every build and nothing prunes it -- 58GB after a day of
# iterating here, enough to fill a disk and take the Docker daemon down with it.
# BuildKit's own cache already makes local rebuilds fast, so the export earns its
# keep in CI, where nothing survives between runs, and not on a workstation.
# Reading an existing export costs nothing, so --cache-from stays unconditional.
CACHE_ARGS=()
if [ -d "${CACHE_DIR}" ]; then
  CACHE_ARGS+=(--cache-from "type=local,src=${CACHE_DIR}/ARCH")
fi
if [ "${PROVERS_EXPORT_BUILD_CACHE:-false}" = "true" ]; then
  echo "Exporting the layer cache to ${CACHE_DIR} (PROVERS_EXPORT_BUILD_CACHE=true)"
  CACHE_ARGS+=(--cache-to "type=local,dest=${CACHE_DIR}/ARCH,mode=max")
fi

# Which architectures this run builds, and whether it pushes them.  The defaults
# are the interactive workstation build: both architectures, then a prompt.  CI
# builds each architecture natively on its own runner (PROVERS_ARCHS=amd64 or
# arm64), answers the prompt up front (PROVERS_PUSH=true/false), and publishes the
# manifests in a final step of its own once both have pushed
# (PROVERS_MANIFEST_ONLY=true).
read -r -a ARCHS <<< "${PROVERS_ARCHS:-arm64 amd64}"
for arch in "${ARCHS[@]}"; do
  case "${arch}" in
    amd64|arm64) ;;
    *) echo "ERROR: PROVERS_ARCHS may only name amd64 and arm64, not '${arch}'." >&2; exit 1 ;;
  esac
done

build_one() {
  local arch=$1
  local args=()
  local a
  for a in "${CACHE_ARGS[@]}"; do
    args+=("${a//ARCH/${arch}}")
  done
  docker buildx build --platform "linux/${arch}" \
    -f "${DOCKERFILE}" \
    -t "${IMAGE}:${arch}_${VERSION}" \
    "${BUILD_ARGS[@]}" \
    "${args[@]}" \
    --load "${CONTEXT}"
}

# The installed tools answer from the image as it ships, before anything is
# pushed.  The image's ENV puts them on PATH without a login shell.
smoke_test() {
  local tag="${IMAGE}:$1_${VERSION}"
  echo "Smoke-testing ${tag}"
  docker run --rm "${tag}" cat provers/build-info &&
  docker run --rm "${tag}" verus --version &&
  docker run --rm "${tag}" sireum --version &&
  docker run --rm "${tag}" bash -c 'ls "${MICROKIT_SDK}/board"'
}

publish_manifests() {
  # Create multi-arch manifest for VERSION
  docker buildx imagetools create \
    -t "${IMAGE}:${VERSION}" \
    "${IMAGE}:arm64_${VERSION}" \
    "${IMAGE}:amd64_${VERSION}"

  # Point latest at the same manifest
  docker buildx imagetools create \
    -t "${IMAGE}:latest" \
    "${IMAGE}:${VERSION}"

  echo "Multi-arch manifest created and 'latest' updated."
}

require_login() {
  if ! grep -qs "index.docker.io" "$HOME/.docker/config.json"; then
    echo "ERROR: Not logged in to Docker Hub. Please run 'docker login' first." >&2
    exit 1
  fi
}

if [ "${PROVERS_MANIFEST_ONLY:-false}" = "true" ]; then
  # both architecture tags were pushed by earlier runs, e.g. one per CI runner
  require_login
  publish_manifests
  exit 0
fi

# Building both at once halves the wall clock but doubles the concurrent load on
# the same hosts -- and the two builds pull hundreds of megabytes from GitHub at
# roughly the same moments, which is a good way to get throttled into a 503 an
# hour into a build.  Set PROVERS_BUILD_SEQUENTIAL=true to build one at a time.
FAILED=0
if [ ${#ARCHS[@]} -eq 1 ] || [ "${PROVERS_BUILD_SEQUENTIAL:-false}" = "true" ]; then
  [ ${#ARCHS[@]} -gt 1 ] && echo "Building sequentially (PROVERS_BUILD_SEQUENTIAL=true)"
  for arch in "${ARCHS[@]}"; do
    build_one "${arch}" || { echo "ERROR: ${arch} build failed."; FAILED=1; }
  done
else
  PIDS=()
  for arch in "${ARCHS[@]}"; do
    build_one "${arch}" & PIDS+=($!)
  done
  for i in "${!ARCHS[@]}"; do
    wait "${PIDS[$i]}" || { echo "ERROR: ${ARCHS[$i]} build failed."; FAILED=1; }
  done
fi
if [ $FAILED -ne 0 ]; then
    exit 1
fi

for arch in "${ARCHS[@]}"; do
  smoke_test "${arch}" || { echo "ERROR: the ${arch} image failed its smoke test."; exit 1; }
done

echo "Built and smoke-tested: ${ARCHS[*]}."
case "${PROVERS_PUSH:-ask}" in
  true) ;;
  false) echo "Skipping push (PROVERS_PUSH=false)."; exit 0 ;;
  *)
    read -r -p "Push images to Docker Hub? [y/N] " answer
    if [[ ! "$answer" =~ ^[Yy]$ ]]; then
        echo "Skipping push."
        exit 0
    fi
    ;;
esac

require_login

for arch in "${ARCHS[@]}"; do
  docker push "${IMAGE}:${arch}_${VERSION}"
done

# The manifest names both architecture tags, so it is published here only when
# this run pushed both; a run that pushed one leaves it to PROVERS_MANIFEST_ONLY.
if [ ${#ARCHS[@]} -eq 2 ]; then
  publish_manifests
else
  echo "Pushed ${IMAGE}:${ARCHS[0]}_${VERSION}; publish the manifests with PROVERS_MANIFEST_ONLY=true once both architectures are pushed."
fi
