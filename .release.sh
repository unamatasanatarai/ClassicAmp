#!/usr/bin/env bash

# Application metadata
APP_NAME="ClassicAmp"

# Pre-release verification command
TEST_CMD="make test"

# Release artifact build command
BUILD_CMD="make dmg"

# Release assets to attach to the GitHub release
RELEASE_ASSETS=(
    'build/ClassicAmp-${version}.dmg'
)
