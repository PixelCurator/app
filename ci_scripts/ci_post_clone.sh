#!/bin/sh

# Xcode Cloud post-clone hook.
#
# The Xcode project (`PixelCurator.xcodeproj`) is git-ignored and generated from
# `project.yml` by xcodegen. Xcode Cloud clones the repo and then expects a
# project + shared scheme to build, so we must generate them here — this hook
# runs after the clone and before dependency resolution / build.
#
# Local development does the same with `xcodegen generate`; this keeps CI and
# local builds reading from the single source of truth (project.yml).

set -e

# Install xcodegen on the ephemeral Xcode Cloud runner.
# (brew is available on Xcode Cloud images. Swap for a pinned release download
#  if build minutes or brew flakiness ever become a concern.)
brew install xcodegen

# CI_PRIMARY_REPOSITORY_PATH points at the checked-out repo root on Xcode Cloud.
cd "$CI_PRIMARY_REPOSITORY_PATH"

# Stamp CURRENT_PROJECT_VERSION with the CI build number BEFORE xcodegen runs,
# so the auto-generated Info.plist (GENERATE_INFOPLIST_FILE=YES) picks up the
# correct build number. This replaces the legacy `agvtool new-version -all`
# step that runs after generation — agvtool can't update CFBundleVersion when
# there is no Info.plist on disk yet and fails with `Cannot find ".../YES"`,
# which used to take down every Xcode Cloud Test action.
#
# CI_BUILD_NUMBER is only set inside Xcode Cloud; locally project.yml stays at
# its committed value so dev builds keep working.
if [ -n "$CI_BUILD_NUMBER" ]; then
    sed -i.bak -E "s/^([[:space:]]+CURRENT_PROJECT_VERSION:)[[:space:]].*/\1 \"$CI_BUILD_NUMBER\"/" project.yml
    rm -f project.yml.bak
    echo "Stamped CURRENT_PROJECT_VERSION = $CI_BUILD_NUMBER in project.yml"
fi

xcodegen generate
