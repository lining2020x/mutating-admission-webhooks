#! /bin/bash
set -e
set -x

[[ "$QUIET" == "yes" ]] && set +x

lib::build::usage() {
  cat >/dev/stderr <<EOF
Usage:
$0 <build-image|push-image|build-chart|push-chart> <WHAT> <ARCH>
EOF
  return 1
}

lib::build::check_required_commands() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || {
      echo "ERROR: $cmd command not found"
      return 1
    }
  done
}

lib::build::binfmt_misc_register() {
  lib::build::check_required_commands docker

  mountpoint -q /proc/sys/fs/binfmt_misc || {
    mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc || {
      echo "ERROR: binfmt_misc mount failed"
      return 1
    }
  }

  # Avoid register binfmt_misc in container and do it on host instead
  # TODO: check whether qemu-aarch64 already registered on host
  local binfmt_flag
  binfmt_flag=$(cat  /proc/sys/fs/binfmt_misc/qemu-aarch64 |grep flags|awk -F : '{print $2}'|tr -d ' ')
  if [[ "${binfmt_flag}" != "F" ]]; then
    echo "WARN: binfmt flag is NOT 'F' in /proc/sys/fs/binfmt_misc/qemu-aarch64, we have to re-register binfmt!"
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
  else
    echo "INFO: binfmt flag checked OK, the flag is 'F' in /proc/sys/fs/binfmt_misc/qemu-aarch64!"
  fi

}

lib::build::check_arch_support() {
  local arch=$1
  if [[ ! "${arch}" =~ (amd64|arm64) ]]; then
    echo "ERROR: ARCH ${arch} not supported, must be amd64 or arm64"
    return 1
  fi

  if [[ "$arch" != "amd64" ]];then
    # check multiarch support
    local kernel_ver=$(uname -r)
    if [[ "${kernel_ver}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)* ]]; then
      major=${BASH_REMATCH[1]}
      minor=${BASH_REMATCH[2]}
      patch=${BASH_REMATCH[3]}
      # kernel version < 4.8 doesn't support running cross arch binaries by binfmt_misc
      # https://medium.com/@artur.klauser/building-multi-architecture-docker-images-with-buildx-27d80f7e2408
      if (( major < 4 || (major == 4 && minor < 8) )) ;then
        echo "ERROR: binfmt_misc not support ${arch} on this kernel version '${kernel_ver}', must be >= 4.8"
	return 1
      fi
    else
      echo "ERROR: invalid host kernel version '${kernel_ver}'"
      return 1
    fi

    # setup binfmt_misc by image `qemu-static-user:latest` for non-amd64 arch when cross building on x86_64 machine
    if [[ "$(uname -m)" == "x86_64" ]];then
      lib::build::binfmt_misc_register
    else
      echo "WARN: building NOT on an amd64 machine, binfmt_misc register skipped!"
    fi
  fi
}

lib::build::check_docker_login() {
  :
}

lib::build::chart_render_notice() {
  cat > /dev/stderr << EOF
Notice for chart rendering:
    1. Only supported value templates of build-helper will be rendered, now supporting:
        {{ IMG_VERSION }} will be replaced with an image version
        {{ CHART_VERSION }} will be replaced with a chart version
        {{ IMAGE_REPO }} will be replaced with a repo, eg: tmp or final.
    2. All files in the chart directory will be processed.
EOF
}

lib::build::chart_render_vars() {
  local chart_dir="$1"

  [[ -d "${chart_dir}" ]] || {
     echo "ERROR: chart dir ${chart_dir} not found or not a directory"
     return 1
  }

  local _sed
  local _find

  if [[ "$OSTYPE" =~ "darwin*" ]]; then
    _sed=gsed
    _find=gfind
  elif [[ "$OSTYPE" =~ "linux-gnu" ]]; then
    _sed=sed
    _find=find
  else
    echo "ERROR: unsupported OSTYPE ${OSTYPE}"
    return 1
  fi

  lib::build::check_required_commands ${_find} ${_sed}

  local files
  files=$(${_find} "${chart_dir}" -type f) || {
    echo "ERROR: find chart files failed"
    return 1
  }

  for f in ${files}; do
    ${_sed} -i \
        -e "s@{{ IMG_VERSION }}@${VERSION}@g" \
        -e "s@{{ CHART_VERSION }}@${CHART_VERSION}@g" \
        -e "s@{{ TOS_IMAGE_REPO }}@${TOS_REPO}@g" \
        "${f}"
  done
}

lib::build::build_image() {
  if [[ -z "${WHAT}" ]]; then
    echo "ERROR: WHAT must be provided for image build, eg: venus-scheduler"
    return 1
  fi

  if [[ -z "${ARCH}" ]]; then
    echo "WARNING: ARCH not provided for image build, using ARCH=amd64, arch supported: amd64, arm64"
    ARCH=amd64
  fi

  lib::build::check_arch_support "${ARCH}"

  if ! [[ -f "build/dockerfiles/${WHAT}/Dockerfile.${ARCH}" ]]; then
    echo "ERROR: build/dockerfiles/${WHAT}/Dockerfile.${ARCH} not found"
    return 1
  fi

  lib::build::check_required_commands docker

  local platform="linux/$ARCH"
  DOCKER_CLI_EXPERIMENTAL=enabled docker buildx build \
    --progress auto \
    --network host \
    --platform "${platform}" \
    --load \
    --label GitVersion="${VERSION}" \
    --label GitCommit="${COMMIT}" \
    --label GitBranch="${BRANCH}" \
    --label GitTreeState="${GIT_TREE_STATE}" \
    --label BuildDate="${TIMESTAMP}" \
    -t "${REGISTRY}/${TOS_REPO}/${WHAT}-${ARCH}:${VERSION}" \
    -f "build/dockerfiles/${WHAT}/Dockerfile.${ARCH}" .

  # TODO: special for amd64 arch for compatibility, remove this when we support multiarch officially.
  if [[ "${ARCH}" == "amd64" ]]; then
    docker tag "${REGISTRY}/${TOS_REPO}/${WHAT}-${ARCH}:${VERSION}" "${REGISTRY}/${TOS_REPO}/${WHAT}:${VERSION}"
  fi
}

lib::build::push_image() {
  if [[ -z "$WHAT" ]]; then
    echo "ERROR: WHAT must be provided for image build, eg: venus-scheduler"
    return 1
  fi

  if [[ -z "${ARCH}" ]]; then
    echo "WARNING: ARCH not provided for image build, supported: amd64, arm64"
    echo "WARNING: ARCH using amd64"
    ARCH=amd64
  fi

  lib::build::check_arch_support "${ARCH}"
  lib::build::check_required_commands docker
  lib::build::check_docker_login

  local image="${REGISTRY}/${TOS_REPO}/${WHAT}-${ARCH}:${VERSION}"
  if [[ -z "$(docker images "${image}" --format {{.Repository}}:{{.Tag}})" ]]; then
    echo "ERROR: image $image not found"
    return 1
  fi

  docker push "$image"

  # TODO: special for amd64 arch for compatibility, remove this when we support multiarch officially.
  if [[ "${ARCH}" == "amd64" ]]; then
    local image="${REGISTRY}/${TOS_REPO}/${WHAT}:${VERSION}"
    if [[ -z "$(docker images "${image}" --format {{.Repository}}:{{.Tag}})" ]]; then
      echo "ERROR: image $image not found"
      return 1
    fi

    docker push "$image"
  fi
}

lib::build::build_chart() {
  if [[ -z "$WHAT" ]]; then
    echo "ERROR: WHAT must be provided for chart build, eg: venus-scheduler"
    return 1
  fi

  local chart_tmpl_dir="build/charts/${WHAT}"

  if ! [[ -d "${chart_tmpl_dir}" ]]; then
    echo "ERROR: chart directory ${chart_tmpl_dir} not found"
    return 1
  fi

  lib::build::chart_render_notice

  local chart_dir="_output/charts/${WHAT}"

  # copy build/charts/<WHAT> to _output/charts/<WHAT>
  [[ -e "${chart_dir}" ]] && rm -rf "${chart_dir}"
  [[ ! -e "_output/charts" ]] && mkdir -p "_output/charts/"
  cp -r "${chart_tmpl_dir}" "${chart_dir}"

  lib::build::chart_render_vars "${chart_dir}"

  lib::build::check_required_commands helm
  helm package --destination _output/charts/ "${chart_dir}"
}

lib::build::push_chart() {
  if [[ -z "$WHAT" ]]; then
    echo "ERROR: WHAT must be provided for chart push, eg: venus-scheduler"
    return 1
  fi

  local chart_pkg="_output/charts/${WHAT}-${CHART_VERSION}.tgz"

  if ! [[ -f "${chart_pkg}" ]]; then
    echo "ERROR: chart package ${chart_pkg} not found"
    return 1
  fi

  lib::build::check_required_commands curl
  curl --data-binary "@${chart_pkg}" --user "chart_controller:cvlPxrJq1QfUmLTB" \
    "http://${REGISTRY}:9999/api/${TOS_REPO}/charts"
}

lib::build::fill_global_vars() {
  lib::build::check_required_commands git date

  local commit_short
  local desc
  local branch
  local git_tree_state

  branch=$(git symbolic-ref --short -q HEAD) || return 1
  commit_short=$(git rev-parse --short HEAD) || return 1
  desc=$(git describe HEAD --tags 2>/dev/null) || {
	desc=""
  }

  # Check if the tree is dirty.  default to dirty
  if git_status=$(git status --porcelain 2>/dev/null) && [[ -z ${git_status} ]]; then
    git_tree_state="clean"
  else
    git_tree_state="dirty"
  fi

  if [[ -z "${desc}" || "${desc}" =~ ^(.*)-([0-9]+)-g${commit_short}$ ]]; then
    # HEAD commit not tagged, eg: v0.4.0-rc.0-83-ga3cc536
    VERSION=${branch}
    CHART_VERSION="0.0.0-${branch}"
    TOS_REPO=${REPO_TMP}
  elif [[ "${desc}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-beta\.([0-9]+)$ ]]; then
    # HEAD commit tagged as a beta stage tag, eg: v0.4.0-beta.0
    VERSION=${desc}
    CHART_VERSION=${desc}
    TOS_REPO=${REPO_TMP}
  elif [[ "${desc}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)-rc\.([0-9]+)$ ]];then
    # HEAD commit tagged as a rc stage tag, eg: v0.4.0-rc.0
    VERSION=${desc}
    CHART_VERSION=${desc}
    TOS_REPO=${REPO_TMP}
  elif [[ "${desc}" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    # HEAD commit tagged as a final stage tag, eg: v0.4.0
    VERSION=${desc}
    CHART_VERSION=${desc}
    TOS_REPO=${REPO_FINAL}
  else
    echo "ERROR: Should never happen!!"
    return 1
  fi

  BRANCH=${branch}
  COMMIT=${commit_short}
  GIT_TREE_STATE=${git_tree_state}
  TIMESTAMP="$(date +"%Y-%m-%dT%H:%M:%S")"
}

ACTION=$1
WHAT=$2
ARCH=$3

REGISTRY=172.16.1.99
REPO_TMP=tmp
REPO_FINAL=final

[[ -z "${ACTION}" || -z "${WHAT}" ]] && {
  lib::build::usage
  exit 1
}

lib::build::fill_global_vars

case ${ACTION} in
  build-image)
    lib::build::build_image
    ;;
  push-image)
    lib::build::push_image
    ;;
  build-chart)
    lib::build::build_chart
    ;;
  push-chart)
    lib::build::push_chart
    ;;
  *)
    lib::build::usage
    ;;
esac
