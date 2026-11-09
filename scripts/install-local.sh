#!/usr/bin/env bash
# Builds Clew (Release) and installs it to ~/Applications, signed with a stable local
# identity so the sandbox container stays the same across rebuilds.
#   scripts/install-local.sh [--launch] [--ad-hoc]
# Copied from Tact, minus its Accessibility signing step (SPEC: Tech).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DERIVED_DATA="${CLEW_DERIVED_DATA_PATH:-/private/tmp/ClewDerivedData}"
INSTALL_DIR="${CLEW_INSTALL_DIR:-${HOME}/Applications}"
IDENTITY_NAME="${CLEW_CODE_SIGN_IDENTITY:-Clew Local Development}"
LAUNCH=false
SIGNING_MODE="local"
STAGING_ROOT=""
PREVIOUS_APP=""
DESTINATION_APP="${INSTALL_DIR}/Clew.app"
LOCK_DIR="${INSTALL_DIR}/.clew-install.lock"
LOCK_PID_FILE="${LOCK_DIR}/pid"
LOCK_OWNED=false
INSTALL_COMMITTED=false

cleanup_install() {
  local status=$?
  local preserve_staging=false
  trap - EXIT HUP INT TERM
  set +e

  if [[ "${INSTALL_COMMITTED}" != true && -n "${PREVIOUS_APP}" && -e "${PREVIOUS_APP}" ]]; then
    if [[ ! -e "${DESTINATION_APP}" ]]; then
      if mv "${PREVIOUS_APP}" "${DESTINATION_APP}"; then
        echo "Previous Clew app restored after the failed install." >&2
      else
        preserve_staging=true
        echo "Automatic restore failed. The previous app is preserved at ${PREVIOUS_APP}." >&2
      fi
    else
      preserve_staging=true
      echo "Install did not commit. The previous app is preserved at ${PREVIOUS_APP}." >&2
    fi
  fi

  if [[ -n "${STAGING_ROOT}" && -d "${STAGING_ROOT}" && "${preserve_staging}" != true ]]; then
    rm -rf "${STAGING_ROOT}"
  fi
  if [[ "${LOCK_OWNED}" == true ]]; then
    rm -f "${LOCK_PID_FILE}"
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi
  exit "${status}"
}

for option in "$@"; do
  case "${option}" in
    --launch) LAUNCH=true ;;
    --ad-hoc) SIGNING_MODE="ad-hoc" ;;
    *) echo "Unknown option: ${option}. Use --ad-hoc and/or --launch." >&2; exit 2 ;;
  esac
done

if [[ -z "${INSTALL_DIR}" || "${INSTALL_DIR}" == "/" || "${INSTALL_DIR}" == "${HOME}" ]]; then
  echo "Install directory is too broad - choose an Applications directory." >&2
  exit 2
fi

mkdir -p "${INSTALL_DIR}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  owner_pid=""
  if [[ -r "${LOCK_PID_FILE}" ]]; then
    read -r owner_pid < "${LOCK_PID_FILE}" || true
  fi
  if [[ "${owner_pid}" =~ ^[0-9]+$ ]] && kill -0 "${owner_pid}" 2>/dev/null; then
    echo "Another Clew install is running (PID ${owner_pid}). Wait for it to finish, then retry." >&2
    exit 1
  fi
  if [[ "${owner_pid}" =~ ^[0-9]+$ ]]; then
    rm -f "${LOCK_PID_FILE}"
    if ! rmdir "${LOCK_DIR}" 2>/dev/null || ! mkdir "${LOCK_DIR}" 2>/dev/null; then
      echo "The stale install lock could not be reclaimed - remove ${LOCK_DIR} after confirming no install is running." >&2
      exit 1
    fi
  else
    echo "An ownerless install lock exists - remove ${LOCK_DIR} after confirming no install is running." >&2
    exit 1
  fi
fi
LOCK_OWNED=true
trap cleanup_install EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "${LOCK_PID_FILE}"

command -v xcodegen >/dev/null 2>&1 || {
  echo "XcodeGen is missing - install it with: brew install xcodegen" >&2
  exit 1
}

if [[ "${SIGNING_MODE}" == "local" ]]; then
  "${SCRIPT_DIR}/create-local-codesign-identity.sh" "${IDENTITY_NAME}"
  SIGNING_ARGUMENTS=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=${IDENTITY_NAME}")
else
  SIGNING_ARGUMENTS=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_IDENTITY=-")
fi

cd "${REPO_ROOT}"
xcodegen generate
xcodebuild \
  -project Clew.xcodeproj \
  -scheme Clew \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA}" \
  "${SIGNING_ARGUMENTS[@]}" \
  build

SOURCE_APP="${DERIVED_DATA}/Build/Products/Release/Clew.app"

[[ -d "${SOURCE_APP}" ]] || {
  echo "Release build succeeded but Clew.app was not found." >&2
  exit 1
}

STAGING_ROOT="$(mktemp -d "${INSTALL_DIR}/.clew-install.XXXXXX")"
STAGED_APP="${STAGING_ROOT}/Clew.app"
PREVIOUS_APP="${STAGING_ROOT}/Previous.app"

ditto "${SOURCE_APP}" "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"

# A menu bar app has no window to close; stop the running copy so the new build
# replaces it instead of running beside it. SQLite (WAL) is safe against this.
if pgrep -x Clew >/dev/null 2>&1; then
  pkill -x Clew || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Clew >/dev/null 2>&1 || break; sleep 0.5; done
fi

if [[ -e "${DESTINATION_APP}" ]]; then
  mv "${DESTINATION_APP}" "${PREVIOUS_APP}"
fi

if ! mv "${STAGED_APP}" "${DESTINATION_APP}"; then
  echo "Install failed before replacement completed." >&2
  exit 1
fi
INSTALL_COMMITTED=true

echo "Installed Clew (${SIGNING_MODE} signing) at ${DESTINATION_APP}"

if [[ "${LAUNCH}" == true ]]; then
  if ! open "${DESTINATION_APP}"; then
    echo "Clew was installed but could not be launched - open ${DESTINATION_APP} manually." >&2
    exit 1
  fi
fi
