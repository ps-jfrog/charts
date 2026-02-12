# Case a: Artifactory SH (source) → Artifactory Cloud (target)
export COMPARE_SOURCE_NEXUS="0"
export COMPARE_TARGET_ARTIFACTORY_SH="1"
export COMPARE_TARGET_ARTIFACTORY_CLOUD="1"
export SH_ARTIFACTORY_BASE_URL="http://34.26.104.216/artifactory/"
export SH_ARTIFACTORY_AUTHORITY="app1"
export CLOUD_ARTIFACTORY_BASE_URL="http://35.237.191.14/artifactory/"
export CLOUD_ARTIFACTORY_AUTHORITY="app2"
export ARTIFACTORY_DISCOVERY_METHOD="artifactory_aql"

# Optional: limit to specific repositories
export SH_ARTIFACTORY_REPOS="sv-docker-local,example-repo-local"
export CLOUD_ARTIFACTORY_REPOS="sv-docker-local,example-repo-local"

# Optional: where to put b4_upload/ and after_upload/ (default: script directory)
export RECONCILE_BASE_DIR="/Users/sureshv/From_Customer/smartsheet/test_a_repo_copy/test2"