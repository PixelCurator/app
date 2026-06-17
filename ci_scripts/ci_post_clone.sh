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
xcodegen generate
