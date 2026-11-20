#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out=".build/java-tests"
mkdir -p "$out"
java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}"
"${java_bin}javac" --release 8 -encoding UTF-8 -d "$out" \
    android/src/local/hanvon/companion/{ResumeFile,RecoveryCleanupPolicy,ContentAccessPolicy,SnapshotCapture}.java \
    android/tests/local/hanvon/companion/*.java
for suite in ResumeFileTest RecoveryCleanupPolicyTest ContentAccessPolicyTest SnapshotCaptureTest; do
    "${java_bin}java" -cp "$out" "local.hanvon.companion.$suite"
done
