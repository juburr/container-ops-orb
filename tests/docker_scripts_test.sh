#!/usr/bin/env bash
#
# Tests for the docker command scripts, run against stub docker and circleci
# commands, so no Docker daemon is needed:
#
# - every PARAM_* variable a script reads is set by each YAML file that runs it
# - docker_build splits build_args on whitespace, one --build-arg per pair,
#   and checks the Dockerfile where docker build -f looks for it
# - docker_pull splits images on whitespace and only warns on a failed pull
# - docker_save refuses to persist an archive_dir other than
#   <workspace_root>/images, the only directory its workspace step persists
#
# Run from a checkout:
#   bash tests/docker_scripts_test.sh

set -euo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts"

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/bin"

# circleci env subst reads its value on stdin; this stub passes it through.
cat > "${TMP}/bin/circleci" << 'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "env" && "${2:-}" == "subst" && $# -eq 2 ]]; then
    cat
    exit 0
fi
exit 1
EOF

# Logs each invocation's arguments, one per line, followed by "--end--".
# "docker save -o FILE" creates FILE. "docker pull" of an image listed in
# DOCKER_PULL_FAIL fails.
cat > "${TMP}/bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" --end-- >> "${DOCKER_LOG}"
case "${1:-}" in
    save) : > "$3" ;;
    pull) [[ " ${DOCKER_PULL_FAIL:-} " != *" $2 "* ]] || exit 1 ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/circleci" "${TMP}/bin/docker"
export PATH="${TMP}/bin:${PATH}"
export DOCKER_LOG="${TMP}/docker.log"
export HOME="${TMP}/home"
export BASH_ENV="${TMP}/bash_env"

FAILURES=0
pass() { printf 'ok: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1"
    FAILURES=$((FAILURES + 1))
}

# run SCRIPT: runs a script from src/scripts in a fresh working directory
# with a fresh docker log. Sets STATUS and OUTPUT.
run() {
    rm -rf "${TMP}/work" "${HOME}" "${DOCKER_LOG}" "${BASH_ENV}"
    mkdir -p "${TMP}/work" "${HOME}"
    : > "${DOCKER_LOG}"
    STATUS=0
    OUTPUT=$(cd "${TMP}/work" && bash "${SCRIPTS}/$1" 2>&1) || STATUS=$?
}

# docker_args_contain ARG...: the docker log holds these lines in sequence.
docker_args_contain() {
    local log want
    log=$'\n'$(cat "${DOCKER_LOG}")$'\n'
    want=$'\n'$(printf '%s\n' "$@")
    [[ "${log}" == *"${want}"* ]]
}

# --- PARAM_* variables agree between the YAML and the scripts it runs --------
# A script must get every PARAM_* it reads. Under src/, the YAML must not set
# a PARAM_* that none of its scripts reads, such as a name left by a rename.
BEFORE=${FAILURES}
for yml in "${ROOT}"/src/commands/*.yml "${ROOT}"/src/jobs/*.yml "${ROOT}/.circleci/test-deploy.yml"; do
    set_vars=$({ grep -oE '^[[:space:]]+PARAM_[A-Z0-9_]+:' "${yml}" || true; } | tr -d ' :' | sort -u)
    read_vars=""
    for script in $({ grep -oE 'scripts/[a-z_/]+\.sh' "${yml}" || true; } | sort -u); do
        script_vars=$({ grep -oE 'PARAM_[A-Z0-9_]+' "${ROOT}/src/${script}" || true; } | sort -u)
        read_vars=$(printf '%s\n%s\n' "${read_vars}" "${script_vars}" | sed '/^$/d' | sort -u)
        missing=$(comm -23 <(printf '%s\n' "${script_vars}") <(printf '%s\n' "${set_vars}"))
        if [[ -n "${missing}" ]]; then
            fail "${yml#"${ROOT}/"} runs ${script} without setting $(echo "${missing}" | tr '\n' ' ')"
        fi
    done
    unread=$(comm -13 <(printf '%s\n' "${read_vars}") <(printf '%s\n' "${set_vars}") | sed '/^$/d')
    if [[ "${yml}" == "${ROOT}/src/"* && -n "${unread}" ]]; then
        fail "${yml#"${ROOT}/"} sets $(echo "${unread}" | tr '\n' ' ')but none of its scripts reads them"
    fi
done
if [[ "${FAILURES}" -eq "${BEFORE}" ]]; then
    pass "PARAM_* variables agree between the YAML and the scripts it runs"
fi

# --- docker_build ------------------------------------------------------------
build_env() {
    export PARAM_IMAGE=app PARAM_TAGS="t1 t2" PARAM_DOCKERFILE=Dockerfile
    export PARAM_BUILD_CONTEXT=. PARAM_TARGET="" PARAM_BUILD_ARGS="" PARAM_EXTRA_ARGS=""
    export PARAM_OCI_LABELS=false PARAM_IMAGE_VERSION="" PARAM_PULL=false
    export PARAM_PLATFORM="" PARAM_BUILDX_BUILDER=""
}
# build_in_work SETUP: runs build.sh after running SETUP in the working directory.
build_in_work() {
    rm -rf "${TMP}/work" "${DOCKER_LOG}"
    mkdir -p "${TMP}/work"
    : > "${DOCKER_LOG}"
    STATUS=0
    OUTPUT=$(cd "${TMP}/work" && eval "$1" && bash "${SCRIPTS}/docker/build.sh" 2>&1) || STATUS=$?
}

build_env
PARAM_BUILD_ARGS=$'A=1 B=2\n  C=3\tD=*\n'
build_in_work 'touch Dockerfile other-file'
if [[ "${STATUS}" -eq 0 ]] && docker_args_contain --build-arg A=1 --build-arg B=2 --build-arg C=3 --build-arg 'D=*' . \
    && [[ "$(grep -c -- '^--build-arg$' "${DOCKER_LOG}")" -eq 4 ]]; then
    pass "build_args split on spaces, tabs and newlines without glob expansion"
else
    fail "build_args split (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}")"
fi

build_env
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -eq 0 ]] && ! grep -qxF -- --build-arg "${DOCKER_LOG}"; then
    pass "empty build_args adds no --build-arg"
else
    fail "empty build_args (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}")"
fi

build_env
PARAM_DOCKERFILE=ctx/Dockerfile PARAM_BUILD_CONTEXT=ctx PARAM_PLATFORM=linux/arm64 PARAM_PULL=true
PARAM_OCI_LABELS=true PARAM_IMAGE_VERSION=1.2.3 PARAM_EXTRA_ARGS="--label 'a=b c'"
build_in_work 'mkdir ctx && touch ctx/Dockerfile'
if [[ "${STATUS}" -eq 0 ]] && docker_args_contain buildx build --platform linux/arm64 --load -f ctx/Dockerfile \
    && docker_args_contain --pull && docker_args_contain --build-arg OCI_VERSION=1.2.3 \
    && docker_args_contain --label 'a=b c' ctx --end--; then
    pass "dockerfile, build_context, platform, pull, image_version and extra_args reach docker"
else
    fail "build parameters (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}")"
fi

build_env
PARAM_BUILD_CONTEXT=ctx
build_in_work 'mkdir ctx && touch ctx/Dockerfile'
if [[ "${STATUS}" -ne 0 ]] && [[ ! -s "${DOCKER_LOG}" ]] && [[ "${OUTPUT}" == *"Set dockerfile to ctx/Dockerfile"* ]]; then
    pass "dockerfile is looked up in the working directory, not build_context"
else
    fail "dockerfile only in build_context should fail (status ${STATUS}): ${OUTPUT}"
fi

# --- docker_pull -------------------------------------------------------------
export PARAM_IMAGES=$'one:1 two:2\nthree:3\n' DOCKER_PULL_FAIL=two:2
run docker/pull.sh
if [[ "${STATUS}" -eq 0 ]] && docker_args_contain pull one:1 --end-- pull two:2 --end-- pull three:3 --end-- \
    && [[ "${OUTPUT}" == *"WARNING: Failed to pull two:2"* ]]; then
    pass "images split on whitespace; a failed pull only warns"
else
    fail "docker_pull (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}") ${OUTPUT}"
fi
unset DOCKER_PULL_FAIL

export PARAM_IMAGES=$' \n '
run docker/pull.sh
if [[ "${STATUS}" -eq 0 ]] && [[ ! -s "${DOCKER_LOG}" ]] && [[ "${OUTPUT}" == *"No images specified"* ]]; then
    pass "whitespace-only images pulls nothing"
else
    fail "whitespace-only images (status ${STATUS}): ${OUTPUT}"
fi

# --- docker_save -------------------------------------------------------------
# save_case NAME WANT(pass|fail) ARCHIVE_DIR PERSIST WORKSPACE_ROOT [SETUP]
save_case() {
    local name=$1 want=$2
    export PARAM_IMAGE=myorg/app PARAM_TAG=t1 PARAM_ARCHIVE_DIR=$3
    export PARAM_PERSIST_TO_WORKSPACE=$4 PARAM_WORKSPACE_ROOT=$5
    rm -rf "${TMP}/work" "${HOME}" "${TMP}/elsewhere" "${DOCKER_LOG}"
    mkdir -p "${TMP}/work" "${HOME}"
    : > "${DOCKER_LOG}"
    STATUS=0
    OUTPUT=$(cd "${TMP}/work" && eval "${6:-:}" && bash "${SCRIPTS}/docker/save.sh" 2>&1) || STATUS=$?
    local saved=no
    if grep -qxF save "${DOCKER_LOG}"; then saved=yes; fi
    if [[ "${want}" == pass && "${STATUS}" -eq 0 && "${saved}" == yes ]] \
        || [[ "${want}" == fail && "${STATUS}" -ne 0 && "${saved}" == no \
            && "${OUTPUT}" == *"archive_dir is not <workspace_root>/images"* ]]; then
        pass "docker_save: ${name}"
    else
        fail "docker_save: ${name} (want ${want}, status ${STATUS}, saved ${saved}): ${OUTPUT}"
    fi
}
# The YAML passes ~ unexpanded, as these cases do; save.sh expands it.
# shellcheck disable=SC2088,SC2016
{
    save_case "default archive_dir ~/images under ~ persists" pass "~/images" true "~"
    if [[ -f "${HOME}/images/myorg-app-img.tar" ]]; then
        pass "docker_save writes <archive_dir>/<image with / as ->-img.tar"
    else
        fail "docker_save did not write ${HOME}/images/myorg-app-img.tar"
    fi
    save_case "relative archive_dir under relative root" pass "images" true "."
    save_case "absolute root with ~ archive_dir" pass "~/images" true "${TMP}/home"
    save_case "other archive_dir with persistence fails" fail "~/out" true "~"
    save_case "nested archive_dir with persistence fails" fail "~/x/images" true "~"
    save_case "symlinked <root>/images fails" fail "~/images" true "~" \
        'mkdir -p ../elsewhere && ln -s ../elsewhere "${HOME}/images"'
    save_case "other archive_dir without persistence" pass "~/out" false "~"
}

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All docker script tests passed."
