#!/usr/bin/env bash
#
# Tests for the docker command scripts, run against stub docker and circleci
# commands, so no Docker daemon is needed:
#
# - every PARAM_* variable a script reads is set by each YAML file that runs it
# - docker_build splits build_args on whitespace, one --build-arg per pair,
#   and checks the Dockerfile where docker build -f looks for it
# - docker_build splits extra_args like shell words without expanding or
#   running anything in it, and fails before docker runs on an unmatched quote
# - docker_build without build_args and extra_args runs docker with no extra
#   arguments, also on bash < 4.4, where an empty array is unset under set -u
# - docker_pull splits images on whitespace and only warns on a failed pull
# - docker_save refuses to persist an archive_dir other than
#   <workspace_root>/images, the only directory its workspace step persists
# - docker_login passes the password on stdin, not as an argument
# - a value a script exports to $BASH_ENV comes back unchanged when a later
#   step sources it, even with a quote and a $(...) in it
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
# DOCKER_PULL_FAIL fails. "docker load" reports loading DOCKER_LOADED_IMAGE,
# if set. "docker login" saves its stdin in DOCKER_STDIN.
cat > "${TMP}/bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" --end-- >> "${DOCKER_LOG}"
case "${1:-}" in
    save) : > "$3" ;;
    pull) [[ " ${DOCKER_PULL_FAIL:-} " != *" $2 "* ]] || exit 1 ;;
    load) [[ -z "${DOCKER_LOADED_IMAGE:-}" ]] || printf 'Loaded image: %s\n' "${DOCKER_LOADED_IMAGE}" ;;
    login) cat > "${DOCKER_STDIN}" ;;
esac
exit 0
EOF
chmod +x "${TMP}/bin/circleci" "${TMP}/bin/docker"
export PATH="${TMP}/bin:${PATH}"
export DOCKER_LOG="${TMP}/docker.log"
export DOCKER_STDIN="${TMP}/docker.stdin"
export HOME="${TMP}/home"
export BASH_ENV="${TMP}/bash_env"

FAILURES=0
pass() { printf 'ok: %s\n' "$1"; }
fail() {
    printf 'FAIL: %s\n' "$1"
    FAILURES=$((FAILURES + 1))
}

# run SCRIPT [SETUP]: runs a script from src/scripts in a fresh working
# directory, after running SETUP there, with a fresh docker log and no
# $BASH_ENV. Sets STATUS and OUTPUT.
run() {
    rm -rf "${TMP}/work" "${HOME}" "${DOCKER_LOG}" "${DOCKER_STDIN}" "${BASH_ENV}"
    mkdir -p "${TMP}/work" "${HOME}"
    : > "${DOCKER_LOG}"
    STATUS=0
    OUTPUT=$(cd "${TMP}/work" && eval "${2:-:}" && bash "${SCRIPTS}/$1" 2>&1) || STATUS=$?
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

# Without build_args and extra_args, BUILD_ARG_ARRAY and SHELL_WORDS are empty.
# Bash before 4.4 treats an empty array as unset under set -u, so unguarded
# expansions of them stop build.sh before docker runs. The exact arguments
# also rule out an empty one in their place.
build_env
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -eq 0 ]] \
    && [[ "$(cat "${DOCKER_LOG}")" == "$(printf '%s\n' build -f Dockerfile -t app:t1 -t app:t2 . --end--)" ]]; then
    pass "no build_args and no extra_args add no arguments (empty arrays on bash < 4.4)"
else
    fail "no build_args and no extra_args (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}") ${OUTPUT}"
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

# extra_args is split like shell words, across lines too, but nothing in it
# is expanded or run: the quoted $(...) and backticks reach docker as text.
build_env
PARAM_EXTRA_ARGS=$(cat << 'END'
--label "cmd=$(touch pwned)" --label 'tick=`touch pwned`'
--label a\ b\\c --label 'C:\dir'
END
)
build_in_work 'touch Dockerfile'
# shellcheck disable=SC2016 # the $(...) and backticks are expected verbatim
if [[ "${STATUS}" -eq 0 ]] && [[ ! -e "${TMP}/work/pwned" ]] \
    && docker_args_contain -t app:t2 --label 'cmd=$(touch pwned)' --label 'tick=`touch pwned`' \
        --label 'a b\c' --label 'C:\dir' . --end--; then
    pass "extra_args are split like shell words; \$(...), backticks and backslashes reach docker as text"
else
    fail "extra_args split (status ${STATUS}, work: $(ls "${TMP}/work")): $(tr '\n' ' ' < "${DOCKER_LOG}")"
fi

# A quoted value may span lines, and double quotes follow the shell's
# backslash rules; '' is an empty argument.
build_env
PARAM_EXTRA_ARGS=$'--label "description=line one\nline two" --label "q=a\\"b\\\\c" --build-arg \'\' --label x=\'it\'"\'"\'s\''
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -eq 0 ]] \
    && docker_args_contain -t app:t2 --label $'description=line one\nline two' --label 'q=a"b\c' \
        --build-arg '' --label "x=it's" . --end--; then
    pass "extra_args keep quoted newlines, backslash escapes in double quotes and empty arguments"
else
    fail "extra_args shell quoting (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}")"
fi

# A # that starts a word starts a comment, which runs to the end of its line
# (a backslash there does not continue it), as eval of the old
# BUILD_CMD+=(...) read it. A # inside a word or in quotes is text.
build_env
PARAM_EXTRA_ARGS=$'--no-cache # not cached \\\n--pull\n--label a#b --label "#q" --label \'\'#x # last'
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -eq 0 ]] \
    && docker_args_contain -t app:t2 --no-cache --pull --label 'a#b' --label '#q' --label '#x' . --end--; then
    pass "extra_args drop # comments but keep a # inside a word or in quotes"
else
    fail "extra_args comments (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}") ${OUTPUT}"
fi

# Outside quotes, a $(...) or backtick fails rather than reaching docker as
# text: whoever wrote it meant it to run, as eval of the old BUILD_CMD+=(...)
# did.
# shellcheck disable=SC2016 # the $(...) and backticks are meant literally
for value in '--label commit=$(git rev-parse HEAD)' '--label n=$((1 + 2))' '--label tick=`date`'; do
    build_env
    PARAM_EXTRA_ARGS=${value}
    build_in_work 'touch Dockerfile'
    label=$(printf '%q' "${value}")
    if [[ "${STATUS}" -ne 0 ]] && [[ ! -s "${DOCKER_LOG}" ]] \
        && [[ "${OUTPUT}" == *"ERROR: extra_args could not be split into arguments"*"outside quotes"* ]]; then
        pass "extra_args with a \$(...) or backtick outside quotes (${label}) fails before docker runs"
    else
        fail "extra_args with a \$(...) or backtick outside quotes (${label}) should fail (status ${STATUS}): ${OUTPUT}"
    fi
done

# Bash's $'...' and $"..." quoting is not implemented, so it fails rather
# than reaching docker with a literal $. A $ in quotes, or before anything
# but a quote, is text.
for value in "--label \$'a b'" '--label $"a b"' "--label x\$'y'"; do
    build_env
    PARAM_EXTRA_ARGS=${value}
    build_in_work 'touch Dockerfile'
    label=$(printf '%q' "${value}")
    if [[ "${STATUS}" -ne 0 ]] && [[ ! -s "${DOCKER_LOG}" ]] \
        && [[ "${OUTPUT}" == *"ERROR: extra_args could not be split into arguments"*"quoting is not supported"* ]]; then
        pass "extra_args with ANSI-C or locale quoting (${label}) fails before docker runs"
    else
        fail "extra_args with ANSI-C or locale quoting (${label}) should fail (status ${STATUS}): ${OUTPUT}"
    fi
done

build_env
PARAM_EXTRA_ARGS="--label \"a\$'b'\" --label 'c\$\"d\"' --label e\$"
build_in_work 'touch Dockerfile'
# shellcheck disable=SC2016 # the $ is expected verbatim
if [[ "${STATUS}" -eq 0 ]] \
    && docker_args_contain -t app:t2 --label "a\$'b'" --label 'c$"d"' --label 'e$' . --end--; then
    pass "a \$ in quotes or before anything but a quote reaches docker as text"
else
    fail "extra_args with a literal \$ (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}") ${OUTPUT}"
fi

build_env
PARAM_EXTRA_ARGS="--no-cache --label 'a=b"
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -ne 0 ]] && [[ ! -s "${DOCKER_LOG}" ]] \
    && [[ "${OUTPUT}" == *"ERROR: extra_args could not be split into arguments"* ]]; then
    pass "extra_args with an unmatched quote fails before docker runs"
else
    fail "extra_args with an unmatched quote should fail (status ${STATUS}): ${OUTPUT}"
fi

# A backslash that ends extra_args escapes nothing (eval of the old
# BUILD_CMD+=(...) failed on it too), so it fails rather than reaching docker.
# That includes a final backslash-newline: the $(...) that reads extra_args
# drops the newline. A backslash-newline between lines joins them as usual.
for value in "--label a=b\\" "--no-cache \\" $'--no-cache \\\n'; do
    build_env
    PARAM_EXTRA_ARGS=${value}
    build_in_work 'touch Dockerfile'
    label=$(printf '%q' "${value}")
    if [[ "${STATUS}" -ne 0 ]] && [[ ! -s "${DOCKER_LOG}" ]] \
        && [[ "${OUTPUT}" == *"ERROR: extra_args could not be split into arguments"* ]]; then
        pass "extra_args ending in a backslash (${label}) fails before docker runs"
    else
        fail "extra_args ending in a backslash (${label}) should fail (status ${STATUS}): ${OUTPUT}"
    fi
done

build_env
PARAM_EXTRA_ARGS=$'--no-cache \\\n--pull\n'
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -eq 0 ]] && docker_args_contain -t app:t2 --no-cache --pull . --end--; then
    pass "extra_args lines joined by a backslash-newline reach docker"
else
    fail "extra_args with backslash-newlines (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}") ${OUTPUT}"
fi

build_env
PARAM_EXTRA_ARGS=$' \t\n '
build_in_work 'touch Dockerfile'
if [[ "${STATUS}" -eq 0 ]] \
    && [[ "$(cat "${DOCKER_LOG}")" == "$(printf '%s\n' build -f Dockerfile -t app:t1 -t app:t2 . --end--)" ]]; then
    pass "whitespace-only extra_args adds no arguments"
else
    fail "whitespace-only extra_args (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}")"
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
    && [[ "${OUTPUT}" == *"WARN: Failed to pull two:2"* ]]; then
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

# --- docker_login ------------------------------------------------------------
# The password must not be in docker's arguments, where other processes can
# read it. "-n" also checks it reaches stdin intact (echo would drop it).
export PARAM_REGISTRY=registry.example PARAM_USERNAME=TEST_REGISTRY_USER PARAM_PASSWORD=TEST_REGISTRY_PASS
export TEST_REGISTRY_USER=user TEST_REGISTRY_PASS=-n
run docker/login.sh
if [[ "${STATUS}" -eq 0 ]] && docker_args_contain login registry.example -u user --password-stdin --end-- \
    && ! grep -qxF -- -n "${DOCKER_LOG}" && [[ "$(cat "${DOCKER_STDIN}")" == "-n" ]]; then
    pass "docker_login passes the password on stdin, not as an argument"
else
    fail "docker_login (status ${STATUS}): $(tr '\n' ' ' < "${DOCKER_LOG}") ${OUTPUT}"
fi
unset TEST_REGISTRY_USER TEST_REGISTRY_PASS

# --- exports to $BASH_ENV ----------------------------------------------------
# Later steps source $BASH_ENV, so a value exported there must come back
# unchanged and run nothing. Wrapped in single quotes instead of quoted with
# printf %q, the quotes in VALUE would end the quoting and $(>pwned) would
# create a file. VALUE has no spaces, since tags are split on them.
VALUE="x'\$(>pwned)'y"

# check_exports SCRIPT [VAR WANT]...: after run SCRIPT, sourcing $BASH_ENV in
# an empty directory sets each VAR to WANT and creates no file there.
check_exports() {
    local script=$1 var want got
    shift
    if [[ "${STATUS}" -ne 0 ]]; then
        fail "${script} with a quote and \$(...) in its values (status ${STATUS}): ${OUTPUT}"
        return
    fi
    rm -rf "${TMP}/source"
    mkdir "${TMP}/source"
    while [[ $# -gt 0 ]]; do
        var=$1 want=$2
        shift 2
        # shellcheck source=/dev/null # written by the script under test
        got=$(cd "${TMP}/source" && source "${BASH_ENV}" > /dev/null 2>&1 && printf '%s' "${!var-(unset)}") \
            || got="(sourcing it failed)"
        if [[ "${got}" != "${want}" ]]; then
            fail "${script}: ${var} came back from \$BASH_ENV as ${got}, not ${want}"
            return
        fi
    done
    if [[ -n "$(ls -A "${TMP}/source")" ]]; then
        fail "${script}: sourcing \$BASH_ENV ran a command from an exported value"
        return
    fi
    pass "${script} exports values with a quote and \$(...) to \$BASH_ENV unchanged"
}

build_env
export PARAM_IMAGE="${VALUE}" PARAM_TAGS="${VALUE} t2"
run docker/build.sh 'touch Dockerfile'
check_exports docker/build.sh BUILT_IMAGE "${VALUE}" BUILT_IMAGE_TAG "${VALUE}" BUILT_IMAGE_FULL "${VALUE}:${VALUE}"

export PARAM_IMAGE="${VALUE}" PARAM_ARCHIVE_DIR=archives DOCKER_LOADED_IMAGE="${VALUE}:${VALUE}"
# shellcheck disable=SC2016 # expanded by run's eval, inside double quotes
run docker/load.sh 'mkdir archives && touch "archives/${PARAM_IMAGE}-img.tar"'
check_exports docker/load.sh LOADED_IMAGE "${VALUE}:${VALUE}"
unset DOCKER_LOADED_IMAGE

export PARAM_IMAGE="${VALUE}" PARAM_TAG="${VALUE}" PARAM_ARCHIVE_DIR=archives
export PARAM_PERSIST_TO_WORKSPACE=false PARAM_WORKSPACE_ROOT=.
run docker/save.sh
check_exports docker/save.sh ARCHIVED_IMAGE_PATH "archives/${VALUE}-img.tar" ARCHIVED_IMAGE_NAME "${VALUE}"

export PARAM_IMAGE="${VALUE}" PARAM_TAGS="${VALUE} t2"
run docker/push.sh
check_exports docker/push.sh PUSHED_IMAGE "${VALUE}" PUSHED_IMAGE_TAG "${VALUE}" PUSHED_IMAGE_FULL "${VALUE}:${VALUE}"

export PARAM_SOURCE_IMAGE="${VALUE}:source" PARAM_TARGET_IMAGE="${VALUE}" PARAM_TAGS="${VALUE} t2"
run docker/tag.sh
check_exports docker/tag.sh TAGGED_IMAGE "${VALUE}" TAGGED_IMAGE_TAG "${VALUE}" TAGGED_IMAGE_FULL "${VALUE}:${VALUE}"

export PARAM_IMAGE="${VALUE}" PARAM_SBOM_FORMAT=spdx-json
# shellcheck disable=SC2016 # expanded by run's eval, inside double quotes
run docker/prepare_attestation.sh 'mkdir sboms && touch "sboms/${PARAM_IMAGE}.spdx.json"'
check_exports docker/prepare_attestation.sh SBOM_FILE "sboms/${VALUE}.spdx.json" PREDICATE_TYPE spdxjson

export PARAM_IMAGE="${VALUE}" PARAM_TAG="${VALUE}" PARAM_IMAGE_SOURCE=local PARAM_ARCHIVE_DIR=archives
export PARAM_REGISTRY="" PARAM_REGISTRY_NAMESPACE="" PARAM_OUTPUT_DIR="${VALUE}" PARAM_OUTPUT_FORMAT=sarif
run grype/prepare_scan.sh
check_exports grype/prepare_scan.sh SCAN_TARGET "${VALUE}:${VALUE}" \
    SCAN_OUTPUT_FILE "${VALUE}/${VALUE}__${VALUE}.grype.sarif" SANITIZED_IMAGE_NAME "${VALUE}__${VALUE}"

# Child bash processes source $BASH_ENV when they start; leave none behind.
rm -f "${BASH_ENV}"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All docker script tests passed."
