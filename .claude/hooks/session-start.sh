#!/bin/bash
# Installs a Linux Swift toolchain for Claude Code on the web so that
# scripts/linux-swift/typecheck.sh can syntax-check every Swift file and
# type-check the platform-independent core. Full builds still need Xcode; see
# .github/workflows/build.yml.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

SWIFT_VERSION="6.1"
SWIFT_HOME="${HOME}/.local/swift-${SWIFT_VERSION}"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/ubuntu2404/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-ubuntu24.04.tar.gz"

if [ ! -x "${SWIFT_HOME}/usr/bin/swiftc" ]; then
    echo "Installing Swift ${SWIFT_VERSION} toolchain into ${SWIFT_HOME}"
    tmp="$(mktemp -d)"
    curl -sSL --retry 3 -o "${tmp}/swift.tar.gz" "${SWIFT_URL}"
    mkdir -p "${SWIFT_HOME}"
    tar -xzf "${tmp}/swift.tar.gz" -C "${SWIFT_HOME}" --strip-components=1
    rm -rf "${tmp}"
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    echo "export PATH=\"${SWIFT_HOME}/usr/bin:\$PATH\"" >> "${CLAUDE_ENV_FILE}"
fi
export PATH="${SWIFT_HOME}/usr/bin:${PATH}"

swiftc --version | head -1
echo "Swift ready. Check the code with: scripts/linux-swift/typecheck.sh"
