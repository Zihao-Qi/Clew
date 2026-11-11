#!/usr/bin/env bash
# Builds the Clew release zip: a universal app signed with the "Clew Local Development"
# identity, the same one install-local.sh uses, so a Homebrew install opens the same data
# (macOS ties the sandbox container to the signature). Used by .github/workflows/release.yml
# and runnable locally.
#   scripts/release-build.sh <version> [output-dir]
# The identity must be in a keychain on the search list and trusted for code signing.
set -euo pipefail

VERSION="${1:?usage: release-build.sh <version> [output-dir]}"
OUT_DIR="${2:-dist}"
IDENTITY_NAME="${CLEW_CODE_SIGN_IDENTITY:-Clew Local Development}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED_DATA="${CLEW_DERIVED_DATA_PATH:-$(mktemp -d)}"
cd "${REPO_ROOT}"

# The tag, the app and the cask must agree, or brew would install something else.
grep -Eq "^ +MARKETING_VERSION: ${VERSION}$" project.yml || { echo "project.yml MARKETING_VERSION is not ${VERSION}" >&2; exit 1; }
grep -Eq "^  version \"${VERSION}\"$" Casks/clew.rb || { echo "Casks/clew.rb version is not ${VERSION}" >&2; exit 1; }

xcodegen generate
xcodebuild \
  -project Clew.xcodeproj \
  -scheme Clew \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${IDENTITY_NAME}" \
  ${CLEW_KEYCHAIN:+OTHER_CODE_SIGN_FLAGS="--keychain ${CLEW_KEYCHAIN}"} \
  build

APP="${DERIVED_DATA}/Build/Products/Release/Clew.app"
codesign --verify --deep --strict "${APP}"
# Signed by the identity, not ad hoc: the designated requirement names its certificate.
# (Captured first: grep -q stops reading early, which pipefail would count as a failure.)
SIGNATURE="$(codesign -d --verbose=2 "${APP}" 2>&1)"
grep -q "^Authority=${IDENTITY_NAME}$" <<<"${SIGNATURE}" || { echo "not signed by ${IDENTITY_NAME}" >&2; exit 1; }
codesign -d -r- "${APP}" 2>&1 | grep designated
lipo -archs "${APP}/Contents/MacOS/Clew"

mkdir -p "${OUT_DIR}"
ZIP="${OUT_DIR}/Clew-${VERSION}.zip"
rm -f "${ZIP}"
ditto -c -k --keepParent "${APP}" "${ZIP}"
shasum -a 256 "${ZIP}"
