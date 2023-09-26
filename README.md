# ReversingLabs rl-secure Jenkins Multibranch Examples

This repository provides two working examples of Jenkins pipeline scripts to illustrate scanning with **rl-secure** - the [ReversingLabs secure.software CLI](https://docs.secure.software/cli/).

The rl-secure CLI tool is capable of scanning [nearly any type](https://docs.secure.software/concepts/language-coverage) of software artifact or package that results from a build.

In these examples, we're using the source code and Maven build instructions for the Struts2 showcase web app, which came with [Apache Struts v2.5.28](https://archive.apache.org/dist/struts/2.5.28/).

The following examples are provided in this repository:

- **[Jenkinsfile_docker](#Jenkinsfile-docker)** - uses the Docker image to scan artifacts
- **[Jenkinsfile-cli](#Jenkinsfile-cli)** - uses the rl-secure CLI directly installed to scan artifacts

The difference between this repository and the other ReversingLabs [Jenkins examples repository](https://github.com/reversinglabs/rl-cli-example-struts2showcase-jenkins) is support for differential package analysis.


## Jenkins requirements

Make sure the [HTML Publisher Jenkins plugin](https://plugins.jenkins.io/htmlpublisher/) is installed.
Both example scripts leverage it to display the ReversingLabs HTML report in the Jenkins UI.

The report won't display correctly unless you change the CSP header as explained in the Jenkins documentation under [Customizing Content Security Policy](http://www.jenkins.io/doc/book/security/configuring-content-security-policy/#customizing-content-security-policy).

For more information on how to integrate rl-secure with Jenkins, follow the [Jenkins integration guide](https://docs.secure.software/cli/integrations/jenkins) in the rl-secure documentation.


## Jenkinsfile-docker

This pipeline script builds the WAR file, scans it using the [ReversingLabs rl-scanner Docker image](https://hub.docker.com/r/reversinglabs/rl-scanner), and stores the reports as build artifacts in JSON, CycloneDX, and SPDX formats.

The HTML report is published as well.

Using the Docker image is ideal for an ephemeral instance of Jenkins because it doesn't require having rl-secure installed.

The script requires that you create the `RLSECURE_ENCODED_LICENSE` and `RLSECURE_SITE_KEY` secret credentials within Jenkins to store your rl-secure [license and site key](https://docs.secure.software/cli/deployment/rl-deploy-quick-start#prepare-the-license-and-site-key).


## Jenkinsfile-cli

This script is designed for a scenario where rl-secure is installed on a persistent (non-ephemeral) Jenkins server.

It assumes rl-secure has been installed to `/bin/RLSecure` and the package store initialized to the same location.

The script builds the WAR file, scans it with rl-secure, and stores the reports as build artifacts in JSON, CycloneDX, and SPDX formats.

The HTML report is published as well.


## Compare artifacts (diff scan)

When scanning an artifact, the full package URL (purl) must always be specified in the format `<project>/<package>@<version>`.

The rl-secure CLI and the rl-scanner Docker image both allow comparing the analysis results of the current artifact with the results of a previous scan in the same `<project>/<package>` context.

Because the previous scan always relates to the same `<project>/<package>` as the current scan,
we only need to specify the artifact `<version>` string with the `--diff-with` parameter.


### Preserve scan results in the package store

To perform diff scans, we need to be able to retain the results of all previous scans.
That means we need a permanent location for the rl-secure package store (`rl-store`).

- If there is only one agent, we can host the `rl-store` directly on the agent itself.
- If there are multiple agents configured, we need to host the `rl-store` external to the agents with NFS or CIFS.

In the examples in this repository, the `rl-store` is hosted on an `NFS` share:

  - /mount/nfs/rl-store


## Multibranch pipelines

When using a multibranch pipeline, it is possible to perform a diff scan on each `push` event in the context of the target branch.

This can show if the latest push improves or worsens the security of the target branch.

The multibranch pipeline will set amongst others, the environment variable **BRANCH_NAME**.

We can use that to automatically construct a package URL in the form of:

- `<user or organization>/<git repository name>-<branch name>@<git commit hash>`

We can extract `<user or organization>` and `<git repository name>` from the **GIT_URL** environment variable.

To detect if a diff scan is needed, we look at the value of `GIT_PREVIOUS_SUCCESSFUL_COMMIT` which directly relates to the `BRANCH_NAME` set by the multibranch pipeline.

The automatic diff scan can be switched off with the `WITH_AUTO_DIFF_SCAN` option when it's not needed; for example, when no scan results exist for a previous successful commit.

Consult the built-in global variable reference at `${YOUR_JENKINS_URL}/pipeline-syntax/globals#env` for a complete, and up to date, list of environment variables available in Pipeline.

## Notes

- With this particular example (based on Apache Struts v2.5.28), the scan will always produce a `FAIL`. Consequently, there won't be any successful commits and the diff scan will never actually run.

- Due to the internal limitations of the operating system and the file system used, it may be possible to create a package URL that exceeds the PATH_MAX (4096) `getconf -a | grep PATH_MAX` or NAME_MAX (255) `getconf -a | grep NAME_MAX`.

- When using pull requests, the multibranch pipeline will create a temporary new branch based on the name of the pull request. As a result, there will never be a `GIT_PREVIOUS_SUCCESSFUL_COMMIT` unless you add additional commits to the pull request.

- A similar event happens on a tag push. A new branch is created with the name of the tag, so no history for the branch will be available and `GIT_PREVIOUS_SUCCESSFUL_COMMIT` will be set to 'null'.

- If you have other ways of detecting a previous commit and want to have full control over the scan and the diff scan, you can set the 2 relevant environment variables yourself and override the automatic package URL generator based on Git environment variables.

  - RL_PACKAGE_URL=`<some project>/<some package>@<some version>`
  - RL_DIFF_WITH=`<a previously scanned version in the same project/package>`


## Useful resources

- The official Jenkins documentation about [multibranch pipelines](https://www.jenkins.io/doc/book/pipeline/multibranch/)
- [ReversingLabs secure.software CLI documentation](https://docs.secure.software/cli/)
- [What is the maximum length of a file path in Ubuntu?](https://askubuntu.com/questions/859945/what-is-the-maximum-length-of-a-file-path-in-ubuntu)
