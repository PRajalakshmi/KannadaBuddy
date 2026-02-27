#!/bin/bash
# Run Flutter Android build with a project-local Gradle home.
# Use this when you see: metadata.bin errors, "Failed to create Jar file", or daemon lock failures.
cd "$(dirname "$0")"
export GRADLE_USER_HOME="$(pwd)/android/.gradle-home"
exec flutter run "$@"
