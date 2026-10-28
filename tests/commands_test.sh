#!/usr/bin/env bash
#
# Tests the command scripts the way the GitHub Actions run them: with no
# circleci CLI on the PATH, against a stand-in docker that records its
# arguments. It checks that:
#
#   - without the CLI, values reach docker as they are: "$NAME" is not
#     expanded, and a value starting with "-" is not taken for an option
#   - docker_build's default tags, ${CIRCLE_SHA1}, which nothing expands
#     without the CLI, fail before docker runs, saying how to set tags
#   - the booleans (docker_build's oci_labels and pull, docker_save's
#     persist_to_workspace) take true or false, as the actions pass them, and
#     CircleCI's 1 or 0, and anything else fails before docker runs
#   - docker_build's OCI label values come from GitHub Actions' variables
#     when CircleCI's are missing
#   - docker_login refuses a username or password that isn't a variable
#     name, without printing it
#   - the scripts write what they export to BASH_ENV
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts/docker"

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# The PATH the scripts run with: links to just the tools they need, and a
# stand-in docker. CircleCI's images have the circleci CLI in /bin and
# /usr/bin, so the system directories can't be on it.
TOOLS="${WORK}/tools"
mkdir -p "${TOOLS}"
for tool in bash cat cut date du grep head ls mkdir tr; do
    if ! path=$(command -v "${tool}"); then
        echo "FAIL: ${tool} is required to run these tests"
        exit 1
    fi
    ln -s "${path}" "${TOOLS}/${tool}"
done

# Records docker's arguments, one per line, each call ended by --end--, and
# login's stdin. docker save writes an empty archive, and docker load reports
# the image Docker would.
cat > "${TOOLS}/docker" << EOF
#!${TOOLS}/bash
printf '%s\n' "\$@" --end-- >> "${WORK}/docker-args"
case "\$1" in
    login) ${TOOLS}/cat > "${WORK}/docker-stdin" ;;
    save) : > "\$3" ;;
    load) echo "Loaded image: app:t1" ;;
esac
exit 0
EOF
chmod +x "${TOOLS}/docker"

FAILURES=0
RC=0
OUTPUT=""

# run SCRIPT VAR=value...: runs a script from src/scripts/docker in
# ${WORK}/work, with the PATH above, a fresh BASH_ENV, and the given
# parameters. Sets RC and OUTPUT.
run() {
    local script=$1
    shift
    rm -f "${WORK}/docker-args" "${WORK}/docker-stdin"
    : > "${WORK}/bash-env"
    OUTPUT=$(cd "${WORK}/work" && env -i HOME="${WORK}/home" PATH="${TOOLS}" BASH_ENV="${WORK}/bash-env" "$@" \
        "${TOOLS}/bash" "${SCRIPTS}/${script}.sh" < /dev/null 2>&1)
    RC=$?
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | %s\n' "${OUTPUT}"
        if [[ -f "${WORK}/docker-args" ]]; then
            printf '    | docker: %s\n' "$(tr '\n' ' ' < "${WORK}/docker-args")"
        fi
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
output_lacks() { ! grep -qF -- "$1" <<< "${OUTPUT}"; }
docker_did_not_run() { [[ ! -f "${WORK}/docker-args" ]]; }
# args_have ARG...: docker was called with these arguments, one after another.
args_have() {
    local want
    want=$(printf '%s\n' "$@")
    [[ -f "${WORK}/docker-args" && $'\n'"$(cat "${WORK}/docker-args")"$'\n' == *$'\n'"${want}"$'\n'* ]]
}
args_lack() { [[ -f "${WORK}/docker-args" ]] && ! grep -qxF -- "$1" "${WORK}/docker-args"; }
bash_env_has() { grep -qxF -- "$1" "${WORK}/bash-env"; }
exported() { printf 'export %s=%q' "$1" "$2"; }

mkdir -p "${WORK}/work" "${WORK}/home"
touch "${WORK}/work/Dockerfile"

check "the scripts run with no circleci CLI on the PATH" \
    bash -c "! PATH='${TOOLS}' command -v circleci"

# ----------------------------------------------------------- docker_build
BUILD_DEFAULTS=(PARAM_IMAGE=app PARAM_TAGS="t1 t2" PARAM_DOCKERFILE=Dockerfile PARAM_BUILD_CONTEXT=.
    PARAM_TARGET="" PARAM_BUILD_ARGS="" PARAM_EXTRA_ARGS="" PARAM_OCI_LABELS=false PARAM_IMAGE_VERSION=""
    PARAM_PULL=false PARAM_PLATFORM="" PARAM_BUILDX_BUILDER="")
# shellcheck disable=SC2016 # $HOME is part of the values, not an expansion
run build "${BUILD_DEFAULTS[@]}" PARAM_IMAGE='-app' PARAM_BUILD_ARGS='HOME_DIR=$HOME' PARAM_EXTRA_ARGS='--label home=$HOME'
check "docker_build: succeeds" rc_is_zero
# shellcheck disable=SC2016 # the values are passed as they are
check "docker_build: passes values as they are, \$NAME and leading - included" \
    args_have build -f Dockerfile -t '-app:t1' -t '-app:t2' --build-arg 'HOME_DIR=$HOME' --label 'home=$HOME' . --end--
check "docker_build: writes the image to BASH_ENV" bash_env_has "$(exported BUILT_IMAGE -app)"
check "docker_build: and its first tag" bash_env_has "$(exported BUILT_IMAGE_TAG t1)"
check "docker_build: and both together" bash_env_has "$(exported BUILT_IMAGE_FULL -app:t1)"

# shellcheck disable=SC2016 # the default is ${CIRCLE_SHA1}, unexpanded
run build "${BUILD_DEFAULTS[@]}" PARAM_TAGS='latest ${CIRCLE_SHA1}' CIRCLE_SHA1=abc123
check "docker_build: tags with a variable nothing expands fail" rc_is_nonzero
check "docker_build: saying there is no CLI to expand it" \
    output_has "ERROR: tags has a \$ in it, but there is no circleci CLI to expand environment variables"
# shellcheck disable=SC2016 # a GitHub Actions expression, not an expansion
check "docker_build: and how to set tags" output_has 'such as a GitHub Actions expression (${{ github.sha }})'
check "docker_build: before docker runs" docker_did_not_run

for value in true 1; do
    run build "${BUILD_DEFAULTS[@]}" PARAM_PULL="${value}" PARAM_OCI_LABELS="${value}" PARAM_IMAGE_VERSION=1.2.3
    check "docker_build: pull ${value} passes --pull" args_have --pull
    check "docker_build: oci_labels ${value} passes the OCI build arguments" args_have --build-arg OCI_VERSION=1.2.3
done
for value in false 0; do
    run build "${BUILD_DEFAULTS[@]}" PARAM_PULL="${value}" PARAM_OCI_LABELS="${value}" PARAM_IMAGE_VERSION=1.2.3
    check "docker_build: pull ${value} passes no --pull" args_lack --pull
    check "docker_build: oci_labels ${value} passes no OCI build arguments" args_lack OCI_VERSION=1.2.3
done
run build "${BUILD_DEFAULTS[@]}" PARAM_OCI_LABELS=yes
check "docker_build: oci_labels yes fails" rc_is_nonzero
check "docker_build: saying what oci_labels takes" output_has "ERROR: oci_labels must be true or false, not 'yes'."
check "docker_build: before docker runs" docker_did_not_run
run build "${BUILD_DEFAULTS[@]}" PARAM_PULL=on
check "docker_build: pull on fails" rc_is_nonzero
check "docker_build: saying what pull takes" output_has "ERROR: pull must be true or false, not 'on'."
check "docker_build: before docker runs" docker_did_not_run

GITHUB_VARS=(GITHUB_SHA=0123abcd GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=myorg/myrepo)
run build "${BUILD_DEFAULTS[@]}" "${GITHUB_VARS[@]}" PARAM_OCI_LABELS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2.0.0
check "docker_build: takes OCI_REVISION from GITHUB_SHA" args_have --build-arg OCI_REVISION=0123abcd
check "docker_build: OCI_VERSION from GITHUB_REF_NAME for a tag" args_have --build-arg OCI_VERSION=v2.0.0
check "docker_build: and OCI_SOURCE from the repository's URL" \
    args_have --build-arg OCI_SOURCE=https://github.example/myorg/myrepo
run build "${BUILD_DEFAULTS[@]}" "${GITHUB_VARS[@]}" PARAM_OCI_LABELS=true GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main
check "docker_build: OCI_VERSION dev for a branch" args_have --build-arg OCI_VERSION=dev
run build "${BUILD_DEFAULTS[@]}" "${GITHUB_VARS[@]}" PARAM_OCI_LABELS=true GITHUB_REF_TYPE=tag GITHUB_REF_NAME=v2.0.0 \
    CIRCLE_SHA1=feed CIRCLE_TAG=v3.0.0 CIRCLE_REPOSITORY_URL=git@github.com:myorg/myrepo.git
check "docker_build: CircleCI's OCI_REVISION first" args_have --build-arg OCI_REVISION=feed
check "docker_build: CircleCI's OCI_VERSION first" args_have --build-arg OCI_VERSION=v3.0.0
check "docker_build: CircleCI's OCI_SOURCE first" args_have --build-arg OCI_SOURCE=git@github.com:myorg/myrepo.git

# ------------------------------------------------------------ docker_save
# shellcheck disable=SC2088 # save.sh expands the ~, as CircleCI passes it
SAVE_DEFAULTS=(PARAM_IMAGE=myorg/app PARAM_TAG=t1 PARAM_ARCHIVE_DIR='~/images' PARAM_PERSIST_TO_WORKSPACE=true
    PARAM_WORKSPACE_ROOT='~')
for value in true 1; do
    run save "${SAVE_DEFAULTS[@]}" PARAM_PERSIST_TO_WORKSPACE="${value}"
    check "docker_save: persist_to_workspace ${value} saves to <workspace_root>/images" \
        args_have save -o "${WORK}/home/images/myorg-app-img.tar" myorg/app:t1 --end--
done
run save "${SAVE_DEFAULTS[@]}" PARAM_ARCHIVE_DIR="${WORK}/out"
check "docker_save: persist_to_workspace true elsewhere fails" rc_is_nonzero
check "docker_save: saying where archive_dir must be" output_has "archive_dir is not <workspace_root>/images"
for value in false 0; do
    run save "${SAVE_DEFAULTS[@]}" PARAM_ARCHIVE_DIR="${WORK}/out" PARAM_PERSIST_TO_WORKSPACE="${value}"
    check "docker_save: persist_to_workspace ${value} saves anywhere" \
        args_have save -o "${WORK}/out/myorg-app-img.tar" myorg/app:t1 --end--
done
check "docker_save: writes the archive's path to BASH_ENV" \
    bash_env_has "$(exported ARCHIVED_IMAGE_PATH "${WORK}/out/myorg-app-img.tar")"
check "docker_save: and its name" bash_env_has "$(exported ARCHIVED_IMAGE_NAME myorg-app)"
run save "${SAVE_DEFAULTS[@]}" PARAM_IMAGE=localhost:5000/myorg/app PARAM_ARCHIVE_DIR="${WORK}/out" \
    PARAM_PERSIST_TO_WORKSPACE=false
check "docker_save: replaces a registry port's : in the archive's name too" \
    args_have save -o "${WORK}/out/localhost-5000-myorg-app-img.tar" localhost:5000/myorg/app:t1 --end--
check "docker_save: and in the name it exports" bash_env_has "$(exported ARCHIVED_IMAGE_NAME localhost-5000-myorg-app)"
run save "${SAVE_DEFAULTS[@]}" PARAM_PERSIST_TO_WORKSPACE=yes
check "docker_save: persist_to_workspace yes fails" rc_is_nonzero
check "docker_save: saying what persist_to_workspace takes" \
    output_has "ERROR: persist_to_workspace must be true or false, not 'yes'."
check "docker_save: before docker runs" docker_did_not_run

# ------------------------------------------------------------ docker_load
run load PARAM_IMAGE=myorg/app PARAM_ARCHIVE_DIR="${WORK}/out"
check "docker_load: succeeds" rc_is_zero
check "docker_load: loads <archive_dir>/<image>-img.tar" args_have load -i "${WORK}/out/myorg-app-img.tar" --end--
check "docker_load: writes the loaded image to BASH_ENV" bash_env_has "$(exported LOADED_IMAGE app:t1)"
run load PARAM_IMAGE=localhost:5000/myorg/app PARAM_ARCHIVE_DIR="${WORK}/out"
check "docker_load: finds the archive docker_save names for a registry port" \
    args_have load -i "${WORK}/out/localhost-5000-myorg-app-img.tar" --end--

# ----------------------------------------------------------- docker_login
LOGIN_DEFAULTS=(REGISTRY_USERNAME=ci-user REGISTRY_PASSWORD=ci-password PARAM_USERNAME=REGISTRY_USERNAME
    PARAM_PASSWORD=REGISTRY_PASSWORD PARAM_REGISTRY='-localhost:5000')
run login "${LOGIN_DEFAULTS[@]}"
check "docker_login: succeeds" rc_is_zero
check "docker_login: passes the registry as it is" args_have login '-localhost:5000' -u ci-user --password-stdin --end--
check "docker_login: and the password on stdin" \
    bash -c "[[ \"\$(cat '${WORK}/docker-stdin')\" == ci-password ]]"
run login "${LOGIN_DEFAULTS[@]}" PARAM_PASSWORD='not-a-name s3cret'
check "docker_login: a password that isn't a variable name fails" rc_is_nonzero
check "docker_login: saying it must be a name" \
    output_has "ERROR: The password parameter must be the name of an environment variable."
check "docker_login: without printing it" output_lacks "s3cret"
check "docker_login: before docker runs" docker_did_not_run
run login "${LOGIN_DEFAULTS[@]}" PARAM_USERNAME='ci user'
check "docker_login: a username that isn't a variable name fails" rc_is_nonzero
check "docker_login: and says so" \
    output_has "ERROR: The username parameter must be the name of an environment variable."
check "docker_login: before docker runs" docker_did_not_run

# ---------------------------------- docker_logout, docker_pull, docker_inspect
run logout PARAM_REGISTRY='-localhost:5000'
check "docker_logout: passes the registry as it is" args_have logout '-localhost:5000' --end--
# shellcheck disable=SC2016 # $BASE is part of the value, not an expansion
run pull PARAM_IMAGES='$BASE alpine:3.20'
# shellcheck disable=SC2016 # the values are passed as they are
check "docker_pull: passes images as they are" args_have pull '$BASE' --end-- pull alpine:3.20 --end--
# shellcheck disable=SC2016 # $TAG is part of the value, not an expansion
run inspect PARAM_IMAGE=myorg/app PARAM_TAG='$TAG'
check "docker_inspect: succeeds" rc_is_zero
# shellcheck disable=SC2016 # the value is passed as it is
check "docker_inspect: passes the tag as it is" args_have image inspect 'myorg/app:$TAG' --end--

# ------------------------------------------------------ docker_tag and push
# shellcheck disable=SC2016 # $SOURCE is part of the value, not an expansion
run tag PARAM_SOURCE_IMAGE='$SOURCE' PARAM_TARGET_IMAGE=localhost:5000/app PARAM_TAGS="v1 latest"
check "docker_tag: succeeds" rc_is_zero
# shellcheck disable=SC2016 # the value is passed as it is
check "docker_tag: passes values as they are" args_have tag '$SOURCE' localhost:5000/app:v1 --end--
check "docker_tag: writes the first tag to BASH_ENV" bash_env_has "$(exported TAGGED_IMAGE_FULL localhost:5000/app:v1)"
run push PARAM_IMAGE=localhost:5000/app PARAM_TAGS="v1 latest"
check "docker_push: succeeds" rc_is_zero
check "docker_push: pushes every tag" args_have push localhost:5000/app:v1 --end-- push localhost:5000/app:latest --end--
check "docker_push: writes the first tag to BASH_ENV" bash_env_has "$(exported PUSHED_IMAGE_FULL localhost:5000/app:v1)"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All command script tests passed."
