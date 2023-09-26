#! /usr/bin/env bash

# ---------------------------------------------------
# Variables inherited from the environment
# ---------------------------------------------------

# MY_ARTIFACT_TO_SCAN: mandatory.
#   Name of the file you want to scan.

# RL_STORE: mandatory.
#   The location of the rl-store, will be initialized automatically on the first run.

# RLSECURE_DIR: mandatory.
#   The location where rl-secure is installed.

# RL_VERBOSE: optional: set to anything but 0 to show feedback during the process.
#   Allow for more feedback during the scan
RL_VERBOSE="${RL_VERBOSE:-0}"

# BUILD_PATH: optional, default '.'.
#   The directory relative to the workspace where we expect the $MY_ARTIFACT_TO_SCAN.
#   We expect the artifact to be in "./$BUILD_PATH/$MY_ARTIFACT_TO_SCAN" relative to the workspace.
#   The default build path is the current directory '.'
BUILD_PATH="${BUILD_PATH:-.}"

# REPORT_PATH: optional, default 'RlReports'.
#   The directory (initially empty) where the analysis reports will be saved, relative to the workspace.
#   The default report path is 'RlReports'.
REPORT_PATH="${REPORT_PATH:-RlReports}"

# WITH_AUTO_DIFF_SCAN: optional, default '1'.
#   Set to anything but 1 to disable the automatic attempt to diff scan.
#   It is enabled by default and auto diff scan is performed if previous scan results are detected.
WITH_AUTO_DIFF_SCAN="${WITH_AUTO_DIFF_SCAN:-1}"

# RL_PACKAGE_URL: optional, default not set, will be automatically detected and created
#   The RL_PACKAGE_URL will be derived from the git environment variables provided by Jenkins.

# RL_DIFF_WITH: optional, default not set, will be automatically detected and created
#   Specifies the artifact version to diff against.
#   For auto diff scan, this is derived from the provided git environment variables

# The above 2 options give you full control over how you want your diff scan to run and what to check against.
# Note the SHA specified as RL_DIFF_WITH must be in the same Project/Package as the current RL_PACKAGE_URL
# Project/Package refers to everything before the @ in the current RL_PACKAGE_URL

# ---------------------------------------------------
# Functions
# ---------------------------------------------------

verifyVarsCli()
{
    if [ -z "${RLSECURE_DIR}" ]
    then
        echo "FATAL: no path specified to the rl-secure installation" >&2
        exit 101
    fi

    RL_SECURE="${RLSECURE_DIR}/rl-secure"
    if [ ! -x "${RL_SECURE}" ]
    then
        echo "FATAL: cannot find the rl-secure executable at: ${RLSECURE_DIR} (${RL_SECURE})" >&2
        exit 101
    fi

    if [ -z "${RL_STORE}" ]
    then
        echo "FATAL: rl-store path was not specified, cannot store the scan history for rl-secure: RL_STORE" >&2
        exit 101
    fi

    if [ -z "${MY_ARTIFACT_TO_SCAN}" ]
    then
        echo "FATAL: nothing to scan, the artifact was not specified in: MY_ARTIFACT_TO_SCAN" >&2
        exit 101
    fi

    if [ ! -f "${BUILD_PATH}/${MY_ARTIFACT_TO_SCAN}" ]
    then
        echo "FATAL: no file found at location 'BUILD_PATH/MY_ARTIFACT_TO_SCAN': ${BUILD_PATH}/${MY_ARTIFACT_TO_SCAN}" >&2
        exit 101
    fi
}

verifyReportDir()
{
    if [ -z "${REPORT_PATH}" ]
    then
        echo "FATAL: no report directory specified" >&2
        exit 101
    fi

    if [ -d "${REPORT_PATH}" ]
    then
        if rmdir "${REPORT_PATH}"
        then
            :
        else
            echo "FATAL: your current REPORT_PATH is not empty" >&2
            exit 101
        fi
    fi

    # make sure that Docker will not create the directory
    mkdir -p "${REPORT_PATH}"
}

fixBranchName()
{
    # note that the default Jenkins pipeline checks out a detached head
    # so no actual branch info may be available
    if [ -z "${BRANCH_NAME}" ]
    then
        BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
    fi
}

extractProjectFromPackageUrl()
{
    echo "${RL_PACKAGE_URL}" |
    awk '{
        sub(/@.*/,"")       # remove the @Version part
        split($0, a , "/")  # we expect $Project/$Package
        print a[1]          # print Project
    }'
}

extractPackageFromPackageUrl()
{
    echo "${RL_PACKAGE_URL}" |
    awk '{
        sub(/@.*/,"")       # remove the @Version part
        split($0, a , "/")  # we expect $Project/$Package
        print a[2]          # print Package
    }'
}

makePackageUrl()
{
    if [ ! -z "${RL_PACKAGE_URL}" ]
    then
        # Split the package URL and find Project and Package
        Project=$( extractProjectFromPackageUrl )
        Package=$( extractPackageFromPackageUrl )
        return
    fi

    # Only build a package URL if none was given by the caller
    # Check if we can make a package URL from the current git context

    # We can use the user or organization as the Project
    Project=$( echo "${GIT_URL}" | awk -F/ '{ print $4 }' )

    # We can use the repository name as the package,
    # but we have to clean up the trailing .git and add the branch to make it unique
    Package=$( echo "${GIT_URL}" | awk -F/ '{ print $5 }' )
    Package=$( basename "${Package}" ".git" )"-${BRANCH_NAME}"

    # as version we use the commit hash
    RL_PACKAGE_URL="${Project}/${Package}@${GIT_COMMIT}"
}

makeDiffWith()
{
    DIFF_WITH=""

    if [ -z "$RL_STORE" ]
    then
        return
    fi

    # Only make a auto diff if none was given by the caller
    if [ ! -z "${RL_DIFF_WITH}" ]
    then
        # Verify the version requested for diff was scanned before
        if [ ! -d "$RL_STORE/.rl-secure/projects/$Project/packages/$Package/versions/$RL_DIFF_WITH" ]
        then
            echo "Cannot do a diff scan: that version has not been scanned yet: ${RL_DIFF_WITH}"
            return
        fi

        DIFF_WITH="--diff-with=${RL_DIFF_WITH}"
        return
    fi

    # Auto diff only if requested
    if [ "${WITH_AUTO_DIFF_SCAN}" != "1" ]
    then
        return
    fi

    if [ -z "${BRANCH_NAME}" ]
    then
        return
    fi

    if [ -z "${GIT_PREVIOUS_SUCCESSFUL_COMMIT}" ]
    then
        return
    fi

    if [ "${GIT_PREVIOUS_SUCCESSFUL_COMMIT}" == "null" ]
    then
        return
    fi

    if [ "${GIT_PREVIOUS_SUCCESSFUL_COMMIT}" == "${GIT_COMMIT}" ]
    then
        return
    fi

    # Verify the previous successful commit was actually scanned before
    if [ ! -d "${RL_STORE}/.rl-secure/projects/${Project}/packages/${Package}/versions/${GIT_PREVIOUS_SUCCESSFUL_COMMIT}" ]
    then
        echo "Cannot do a diff scan: that version has not been scanned yet: ${GIT_PREVIOUS_SUCCESSFUL_COMMIT}"
        return
    fi

    DIFF_WITH="--diff-with=${GIT_PREVIOUS_SUCCESSFUL_COMMIT}"
}

reportCurrentJenkinsEnv()
{
    if [ "${RL_VERBOSE}" == "0" ]
    then
        return
    fi

    cat <<!
Feedback: ----------------------------------------
RLSECURE_DIR:           ${RLSECURE_DIR}
RL_STORE:               ${RL_STORE:-'No rl-store was specified, diff scan is not possible.'}
MY_ARTIFACT_TO_SCAN:    ${MY_ARTIFACT_TO_SCAN}
BUILD_PATH:             ${BUILD_PATH}
REPORT_PATH:            ${REPORT_PATH}

GIT_COMMIT:             ${GIT_COMMIT}
GIT_PREVIOUS_COMMIT:    ${GIT_PREVIOUS_COMMIT}
GIT_PREVIOUS_SUCCESSFUL_COMMIT: ${GIT_PREVIOUS_SUCCESSFUL_COMMIT:-'No previous successful commit available to diff against.'}
BRANCH_NAME:            ${BRANCH_NAME}
TAG_NAME:               ${TAG_NAME:-'No tag name available.'}

WITH_AUTO_DIFF_SCAN:    ${WITH_AUTO_DIFF_SCAN}
Project:                ${Project}
Package:                ${Package}
RL_PACKAGE_URL:         ${RL_PACKAGE_URL}
RL_DIFF_WITH:           ${RL_DIFF_WITH:-'No manual diff scan override was requested.'}
DIFF_WITH:              ${DIFF_WITH:-'No diff scan will be executed, see RL_STORE, RL_DIFF_WITH, GIT_PREVIOUS_SUCCESSFUL_COMMIT or WITH_AUTO_DIFF_SCAN.'}

!
}

scan_cli()
{
    ${RL_SECURE} scan "${BUILD_PATH}/${MY_ARTIFACT_TO_SCAN}" \
        --rl-store ${RL_STORE} \
        --purl ${RL_PACKAGE_URL} \
        --replace \
        --no-tracking

    ${RL_SECURE} report \
        --rl-store ${RL_STORE} \
        --purl ${RL_PACKAGE_URL} \
        --format all \
        --no-tracking \
        --output-path ${REPORT_PATH} \
        ${DIFF_WITH}

    ${RL_SECURE} status \
        --rl-store ${RL_STORE} \
        --purl ${RL_PACKAGE_URL} \
        --return-status \
        --no-color
}

# ---------------------------------------------------
# The program flow
# ---------------------------------------------------

main()
{
    verifyVarsCli
    verifyReportDir
    fixBranchName
    makePackageUrl
    makeDiffWith
    reportCurrentJenkinsEnv
    scan_cli
}

main
