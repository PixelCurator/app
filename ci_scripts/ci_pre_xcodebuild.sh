#!/bin/sh

# Xcode Cloud pre-build hook.
#
# Intentionally a no-op. Build-number stamping moved to ci_post_clone.sh
# (substitute CURRENT_PROJECT_VERSION in project.yml before xcodegen) because
# the old `agvtool new-version -all` approach can't write CFBundleVersion when
# GENERATE_INFOPLIST_FILE=YES — there is no Info.plist on disk for agvtool to
# touch, and it fails with `Cannot find ".../YES"`, which killed every Test
# action with exit code 3 before xcodebuild even started.
#
# Keeping this script around (even as a no-op) so Xcode Cloud's workflow can
# still find a Pre-Build hook. If you need a real pre-build step in the
# future, add it here — but do NOT reintroduce agvtool against the
# auto-generated Info.plist.

set -e

exit 0
