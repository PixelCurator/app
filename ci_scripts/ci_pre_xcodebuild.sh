#!/bin/sh

# Xcode Cloud pre-build hook.
#
# Stamps the archive's build number with Xcode Cloud's monotonic CI_BUILD_NUMBER
# so TestFlight/App Store uploads always have a unique, increasing build number
# without hand-editing CURRENT_PROJECT_VERSION. No-op locally (CI_BUILD_NUMBER
# is only set inside Xcode Cloud), so local builds keep project.yml's value.
#
# Runs after ci_post_clone.sh has generated the project, right before xcodebuild.

set -e

if [ -n "$CI_BUILD_NUMBER" ]; then
    cd "$CI_PRIMARY_REPOSITORY_PATH"
    # apple-generic versioning is active (CURRENT_PROJECT_VERSION is set in project.yml).
    agvtool new-version -all "$CI_BUILD_NUMBER"
fi
