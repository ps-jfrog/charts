# Case a: Artifactory SH (source) → Artifactory Cloud (target)
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="https://psazuse.jfrog.io/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="psazuse"
export CLOUD_ARTIFACTORY_BASE_URL="https://psazuse.jfrog.io/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="psazuse1"
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"

# Optional: limit to specific repositories
export SH_ARTIFACTORY_REPOS="npmjs-remote-cache"
export CLOUD_ARTIFACTORY_REPOS="sv-npmjs-remote-cache-copy"
# export CLOUD_ARTIFACTORY_REPOS="sv-docker-local-copy,example-repo-local-copy"


# Optional: where to put b4_upload/ and after_upload/ (default: script directory)
export RECONCILE_BASE_DIR="/Users/sureshv/mycode/ps-jfrog/charts/ps/Testing_files_transfer/compare_source_to_target_and_fixrepodiff/test/test7_npm_sha1-prefix"