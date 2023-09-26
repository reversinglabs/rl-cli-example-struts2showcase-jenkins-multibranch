#! /usr/bin/env bash

# ---------------------------------------------------
# Variables inherited from the environment
# ---------------------------------------------------

# RLSECURE_ENCODED_LICENSE: mandatory.
#   The Base64-encoded license for your rl-secure installation

# RLSECURE_SITE_KEY: mandatory.
#   The site key for your license

# MY_ARTIFACT_TO_SCAN: mandatory.
#   Name of the file you want to scan.

# RL_STORE: optional.
#   The location of the rl-store, will be initialized automatically on the first run.
#   If no store is available, the diff scan can't be done and
#     we ignore the PackageUrl if provided
#     as we have only a Docker-based temporary store for one scan

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
#   The default report path is 'RlReports'
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

verifyVarsDocker()
{
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
        print a[0]          # print Project
    }'
}

extractPackageFromPackageUrl()
{
    echo "${RL_PACKAGE_URL}" |
    awk '{
        sub(/@.*/,"")       # remove the @Version part
        split($0, a , "/")  # we expect $Project/$Package
        print a[1]          # print Package
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

    # Only make an auto diff if none was given by the caller
    if [ ! -z "${RL_DIFF_WITH}" ]
    then
        if [ ! -d "$RL_STORE/.rl-secure/projects/$Project/packages/$Package/versions/$RL_DIFF_WITH" ]
        then
            echo "That version has not been scanned yet: ${RL_DIFF_WITH}"
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

    if [ ! -d "${RL_STORE}/.rl-secure/projects/${Project}/packages/${Package}/versions/${GIT_PREVIOUS_SUCCESSFUL_COMMIT}" ]
    then
        echo "That version has not been scanned yet: ${GIT_PREVIOUS_SUCCESSFUL_COMMIT}"
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

scan_docker_with_store()
{
    # Don't let Docker create directories, it will make them root:root
    # If the Jenkins job creates them,
    # they will be the user you expect (e.g. jenkins:jenkins)
    # See: verifyReportDir

    docker run --rm -u $(id -u):$(id -g) \
        -e RLSECURE_ENCODED_LICENSE=${RLSECURE_ENCODED_LICENSE} \
        -e RLSECURE_SITE_KEY=${RLSECURE_SITE_KEY} \
        -v "$(realpath ${BUILD_PATH}):/packages:ro" \
        -v "$(realpath ${REPORT_PATH}):/report" \
        -v "${RL_STORE}:/rl-store" \
        reversinglabs/rl-scanner:latest \
            rl-scan \
                --rl-store /rl-store \
                --purl ${RL_PACKAGE_URL} \
                --replace \
                --package-path=/packages/${MY_ARTIFACT_TO_SCAN} \
                --report-path=/report \
                --report-format=all \
                ${DIFF_WITH}
}

scan_docker_no_store()
{
    # Don't let Docker create directories, it will make them root:root
    # If the Jenkins job creates them,
    # they will be the user you expect (e.g. jenkins:jenkins)
    # See: verifyReportDir

    docker run --rm -u $(id -u):$(id -g) \
        -e RLSECURE_ENCODED_LICENSE=${RLSECURE_ENCODED_LICENSE} \
        -e RLSECURE_SITE_KEY=${RLSECURE_SITE_KEY} \
        -v "$(realpath ${BUILD_PATH}):/packages:ro" \
        -v "$(realpath ${REPORT_PATH}):/report" \
        reversinglabs/rl-scanner:latest \
            rl-scan \
                --replace \
                --package-path=/packages/${MY_ARTIFACT_TO_SCAN} \
                --report-path=/report \
                --report-format=all
}

# ---------------------------------------------------
# The program flow
# ---------------------------------------------------

main()
{
    verifyVarsDocker
    verifyReportDir
    fixBranchName
    makePackageUrl
    makeDiffWith
    reportCurrentJenkinsEnv

    if [ -z "$RL_STORE" ]
    then
        scan_docker_no_store
    else
        scan_docker_with_store
    fi
}

main
