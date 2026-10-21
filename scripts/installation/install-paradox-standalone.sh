#!/usr/bin/env bash

# ParadoxLab Installation Script
# Installs ParadoxLab from an owner-published standalone archive or local archive.
# This script intentionally does not install Node.js or change npm config.
#
# Usage:
#   install-paradox-standalone.sh --source [github|npm|internal|local-build]
#   install-paradox-standalone.sh --method [standalone|npm]

if [ -z "${BASH_VERSION}" ] && [ -z "${__PARADOX_INSTALL_REEXEC:-}" ]; then
    if command -v bash >/dev/null 2>&1; then
        if [ -f "${0}" ]; then
            export __PARADOX_INSTALL_REEXEC=1
            exec bash -- "${0}" "$@"
        fi

        echo "Error: This script requires bash. Run the installer with: curl ... | bash"
        exit 1
    fi

    echo "Error: This script requires bash. Please install bash first."
    exit 1
fi

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MUTED='\033[0;2m'
NC='\033[0m'
BRAND_ORANGE='\033[38;5;214m'

supports_truecolor() {
    [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]
}

if supports_truecolor; then
    BRAND_BLUE='\033[38;2;71;150;228m'
    BRAND_PURPLE='\033[38;2;132;122;206m'
else
    BRAND_BLUE='\033[38;5;68m'
    BRAND_PURPLE='\033[38;5;140m'
fi

log_info() {
    printf '%bINFO:%b %s\n' "${BLUE}" "${NC}" "$1"
}

log_success() {
    printf '%bSUCCESS:%b %s\n' "${GREEN}" "${NC}" "$1"
}

log_warning() {
    printf '%bWARNING:%b %s\n' "${YELLOW}" "${NC}" "$1"
}

log_error() {
    printf '%bERROR:%b %s\n' "${RED}" "${NC}" "$1" >&2
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_terminal() {
    [ -t 2 ]
}

print_progress() {
    local bytes="$1"
    local length="$2"
    [ "$length" -gt 0 ] || return 0
    local width=50
    local percent=$(( bytes * 100 / length ))
    [ "$percent" -gt 100 ] && percent=100
    local on=$(( percent * width / 100 ))
    local off=$(( width - on ))
    local filled=$(printf "%*s" "$on" "")
    filled=${filled// /■}
    local empty=$(printf "%*s" "$off" "")
    empty=${empty// /･}
    printf "\r${BRAND_ORANGE}%s%s %3d%%${NC}" "$filled" "$empty" "$percent" >&2
}

finish_progress() {
    print_progress 1 1
    echo "" >&2
}

TEMP_DIRS=()
ACTIVE_DOWNLOAD_PID=""
PATH_UPDATE_APPLIED=0
# PATH as inherited from the invoking shell. The script later prepends the
# install dir to its own PATH, but that never propagates to the parent shell
# (a piped `curl | bash` runs in a child process), so we keep the original
# value to decide whether the user must reload their shell rc file.
ORIGINAL_PATH="${PATH:-}"

cleanup_temp_dirs() {
    local temp_dir
    for temp_dir in "${TEMP_DIRS[@]}"; do
        if [[ -n "${temp_dir}" ]]; then
            rm -rf "${temp_dir}"
        fi
    done
}

register_temp_dir() {
    local temp_dir="$1"
    TEMP_DIRS+=("${temp_dir}")
}

restore_cursor() {
    printf "\033[?25h"
}

kill_active_download() {
    if [[ -n "${ACTIVE_DOWNLOAD_PID}" ]]; then
        kill "${ACTIVE_DOWNLOAD_PID}" 2>/dev/null || true
        ACTIVE_DOWNLOAD_PID=""
    fi
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

display_install_version() {
    if [[ "${VERSION}" == "latest" ]]; then
        echo "latest"
        return 0
    fi

    echo "${VERSION#v}"
}

trap cleanup_temp_dirs EXIT
trap 'restore_cursor >&2; kill_active_download; cleanup_temp_dirs; exit 130' INT
trap 'restore_cursor >&2; kill_active_download; cleanup_temp_dirs; exit 143' TERM

print_usage() {
    cat <<EOF
ParadoxLab Installer

Usage: $0 [OPTIONS]

Options:
  --method METHOD      Install method: standalone or npm (default: standalone)
  --base-url URL       Override standalone archive base URL
  --archive PATH       Install from a local standalone archive
  --version VERSION    Release version (default: latest)
  --registry URL       npm registry (default: https://registry.npmjs.org)
  --no-modify-path     Do not modify shell rc file
  -s, --source SOURCE  Record installation source
  -h, --help           Show this help message

Example:
  curl -fsSL https://raw.githubusercontent.com/Damdiyal/paradox-cli/main/scripts/installation/install-paradox-standalone.sh | bash
EOF
}

SOURCE="unknown"
METHOD="${PARADOX_INSTALL_METHOD:-}"
BASE_URL="${PARADOX_INSTALL_BASE_URL:-}"
ARCHIVE_PATH="${PARADOX_INSTALL_ARCHIVE:-}"
VERSION="${PARADOX_INSTALL_VERSION:-latest}"
NO_MODIFY_PATH="${PARADOX_NO_MODIFY_PATH:-0}"
NPM_REGISTRY="${PARADOX_NPM_REGISTRY:-https://registry.npmjs.org}"
INSTALL_ROOT="${PARADOX_INSTALL_ROOT:-${HOME:-}/.local}"
if [[ -n "${PARADOX_INSTALL_LIB_DIR:-}" ]]; then
    INSTALL_LIB_DIR="${PARADOX_INSTALL_LIB_DIR}"
    INSTALL_LIB_PARENT="$(dirname "${INSTALL_LIB_DIR}")"
else
    INSTALL_LIB_PARENT="${PARADOX_INSTALL_LIB_PARENT:-${INSTALL_ROOT}/lib}"
    INSTALL_LIB_DIR="${INSTALL_LIB_PARENT}/paradoxcli"
fi
INSTALL_BIN_DIR="${PARADOX_INSTALL_BIN_DIR:-${INSTALL_ROOT}/bin}"

validate_source() {
    if [[ "${SOURCE}" == "unknown" ]]; then
        return 0
    fi

    if [[ "${SOURCE}" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 0
    fi

    log_error "--source may only contain letters, numbers, dot, underscore, or dash."
    exit 1
}

validate_https_url() {
    local value="$1"
    local option_name="$2"

    if [[ -z "${value}" ]]; then
        return 0
    fi

    if [[ "${value}" == https://* ]]; then
        return 0
    fi

    log_error "${option_name} must start with https://"
    exit 1
}

validate_version() {
    if [[ "${VERSION}" == "latest" ]]; then
        return 0
    fi

    if [[ "${VERSION}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
        return 0
    fi

    log_error "--version must be 'latest' or a semver string."
    exit 1
}

validate_github_repo() {
    local github_repo="${PARADOX_INSTALL_GITHUB_REPO:-Damdiyal/paradox-cli}"
    if [[ "${github_repo}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
        return 0
    fi

    log_error "PARADOX_INSTALL_GITHUB_REPO must be in owner/repo format."
    exit 1
}

validate_install_path() {
    local value="$1"
    local option_name="$2"

    if [[ -z "${value}" ]]; then
        log_error "${option_name} must not be empty."
        exit 1
    fi

    case "${value}" in
        *$'\n'*|*$'\r'*)
            log_error "${option_name} must not contain newlines."
            exit 1
            ;;
    esac

    if [[ "${value}" != /* ]]; then
        log_error "${option_name} must be an absolute path."
        exit 1
    fi
}

validate_options() {
    METHOD="${METHOD:-standalone}"

    case "${METHOD}" in
        standalone|detect|npm)
            ;;
        *)
            log_error "--method must be standalone, detect, or npm. Automatic fallback is disabled."
            exit 1
            ;;
    esac

    # Retain the old command spelling as a strict standalone alias. It never
    # changes source when a download or verification step fails.
    [[ "${METHOD}" == "detect" ]] && METHOD="standalone"

    validate_https_url "${BASE_URL}" "--base-url"
    validate_https_url "${NPM_REGISTRY}" "--registry"
    validate_version
    validate_github_repo
    validate_install_path "${INSTALL_ROOT}" "PARADOX_INSTALL_ROOT"
    validate_install_path "${INSTALL_LIB_PARENT}" "PARADOX_INSTALL_LIB_PARENT"
    validate_install_path "${INSTALL_LIB_DIR}" "PARADOX_INSTALL_LIB_DIR"
    validate_install_path "${INSTALL_BIN_DIR}" "PARADOX_INSTALL_BIN_DIR"
    validate_source
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                log_error "--source requires a value"
                exit 1
            fi
            SOURCE="$2"
            shift 2
            ;;
        --method)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                log_error "--method requires a value"
                exit 1
            fi
            METHOD="$2"
            shift 2
            ;;
        --base-url)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                log_error "--base-url requires a value"
                exit 1
            fi
            validate_https_url "$2" "--base-url"
            BASE_URL="$2"
            shift 2
            ;;
        --archive)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                log_error "--archive requires a value"
                exit 1
            fi
            ARCHIVE_PATH="$2"
            shift 2
            ;;
        --version)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                log_error "--version requires a value"
                exit 1
            fi
            VERSION="$2"
            shift 2
            ;;
        --registry)
            if [[ -z "${2:-}" ]] || [[ "${2:-}" == -* ]]; then
                log_error "--registry requires a value"
                exit 1
            fi
            NPM_REGISTRY="$2"
            shift 2
            ;;
        --no-modify-path)
            NO_MODIFY_PATH=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo ""
            print_usage
            exit 1
            ;;
    esac
done

# Validate all user-supplied options before doing network or filesystem work.
validate_options

print_header() {
    echo ""
    echo "Installing ParadoxLab version: $(display_install_version)"
    echo ""
}

print_node_help() {
    echo ""
    echo "Node.js 22 or newer is required. Install from https://nodejs.org/ then rerun."
    echo "  brew install node"
}

require_node() {
    if ! command_exists node; then
        log_error "Node.js was not found."
        print_node_help
        return 1
    fi

    local node_version
    node_version=$(node -p "process.versions.node" 2>/dev/null || true)
    local node_major
    node_major=$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || true)

    if [[ -z "${node_major}" ]] || ! [[ "${node_major}" =~ ^[0-9]+$ ]]; then
        log_error "Unable to determine Node.js version."
        print_node_help
        return 1
    fi

    if [[ "${node_major}" -lt 22 ]]; then
        log_error "Node.js ${node_version:-unknown} is installed, but Node.js 22 or newer is required."
        print_node_help
        return 1
    fi
}

require_npm() {
    if command_exists npm; then
        return 0
    fi

    log_error "npm was not found. Install Node.js with npm from https://nodejs.org/"
    return 1
}

get_npm_global_bin() {
    local prefix
    prefix=$(npm prefix -g 2>/dev/null || true)

    if [[ -z "${prefix}" ]]; then
        return 0
    fi

    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*)
            echo "${prefix}"
            ;;
        *)
            echo "${prefix}/bin"
            ;;
    esac
}

get_npm_global_root() {
    npm root -g 2>/dev/null || true
}

create_source_json() {
    if [[ "${SOURCE}" == "unknown" ]]; then
        return 0
    fi

    local paradox_dir="${HOME}/.paradox"
    mkdir -p "${paradox_dir}"

    local escaped_source
    escaped_source=$(printf '%s' "${SOURCE}" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "${paradox_dir}/source.json" <<EOF
{
  "source": "${escaped_source}"
}
EOF
}

detect_target() {
    local os
    os=$(uname -s 2>/dev/null || echo unknown)
    local arch
    arch=$(uname -m 2>/dev/null || echo unknown)

    case "${os}" in
        Darwin)
            echo "macOS is no longer a supported Paradox standalone target." >&2
            return 1
            ;;
        Linux)
            os="linux"
            ;;
        *)
            return 1
            ;;
    esac

    case "${arch}" in
        x86_64|amd64)
            arch="x64"
            ;;
        arm64|aarch64)
            arch="arm64"
            ;;
        *)
            return 1
            ;;
    esac

    echo "${os}-${arch}"
}

archive_extension_for_target() {
    case "$1" in
        linux-*)
            echo "tar.gz"
            ;;
        *)
            return 1
            ;;
    esac
}

release_version_path() {
    if [[ "${VERSION}" == "latest" ]]; then
        echo "latest"
        return 0
    fi

    case "${VERSION}" in
        v*)
            echo "${VERSION}"
            ;;
        *)
            echo "v${VERSION}"
            ;;
    esac
}

# When an existing `paradox` is detected, append a PATH prepend to the user's
# shell rc file at the very end. Putting it at the END means our prepend runs
# AFTER any earlier PATH munging in the rc file (e.g., other tools' shell
# init), so our installed_bin wins. Idempotent via a marker comment.
maybe_update_shell_path() {
    local install_bin_dir="$1"

    [[ "${NO_MODIFY_PATH:-0}" == "1" ]] && return 0
    [[ -z "${install_bin_dir}" ]] && return 0
    [[ -z "${HOME:-}" ]] && return 0

    local rc_file=""
    case "${SHELL:-}" in
        */zsh)  rc_file="${HOME}/.zshrc" ;;
        */bash)
            if [[ -f "${HOME}/.bashrc" ]]; then
                rc_file="${HOME}/.bashrc"
            elif [[ -f "${HOME}/.bash_profile" ]]; then
                rc_file="${HOME}/.bash_profile"
            else
                rc_file="${HOME}/.bashrc"
            fi
            ;;
        */fish) rc_file="${HOME}/.config/fish/config.fish" ;;
        *)
            log_warning "Unsupported shell for automatic PATH update: ${SHELL:-unknown}. Add ${install_bin_dir} to PATH manually."
            return 0
            ;;
    esac

    [[ -z "${rc_file}" ]] && return 0

    local begin_marker="# ParadoxLab PATH block begin"
    local end_marker="# ParadoxLab PATH block end"
    local quoted_install_bin_dir
    quoted_install_bin_dir=$(shell_quote "${install_bin_dir}")
    local export_line
    if [[ "${rc_file}" == *config.fish ]]; then
        export_line="set -gx PATH ${quoted_install_bin_dir} \$PATH"
    else
        export_line="export PATH=${quoted_install_bin_dir}:\$PATH"
    fi

    if [[ -f "${rc_file}" ]] && grep -qxF "${export_line}" "${rc_file}" 2>/dev/null; then
        local current_tail
        current_tail=$(tail -n 3 "${rc_file}" 2>/dev/null || true)
        if [[ "${current_tail}" == "${begin_marker}"$'\n'"${export_line}"$'\n'"${end_marker}" ]]; then
            PATH_UPDATE_APPLIED=1
            PATH_UPDATE_RC_FILE="${rc_file}"
            return 0
        fi
    fi

    mkdir -p "$(dirname "${rc_file}")" 2>/dev/null || true
    {
        echo ""
        echo "${begin_marker}"
        echo "${export_line}"
        echo "${end_marker}"
    } >> "${rc_file}" || {
        log_warning "Could not write PATH update to ${rc_file}."
        return 0
    }

    PATH_UPDATE_APPLIED=1
    PATH_UPDATE_RC_FILE="${rc_file}"
}

github_base_url_for_version() {
    local version_path="$1"
    local github_repo="${PARADOX_INSTALL_GITHUB_REPO:-Damdiyal/paradox-cli}"
    if [[ "${version_path}" == "latest" ]]; then
        echo "https://github.com/${github_repo}/releases/latest/download"
    else
        echo "https://github.com/${github_repo}/releases/download/${version_path}"
    fi
}

standalone_base_url() {
    if [[ -n "${BASE_URL}" ]]; then
        echo "${BASE_URL%/}"
        return 0
    fi
    github_base_url_for_version "$(release_version_path)"
}

get_content_length() {
    local url="$1"
    curl -fsSLI --retry 1 --connect-timeout 10 --max-time 15 "${url}" 2>/dev/null \
        | grep -i '^content-length:' | tail -1 | tr -d '\r' | awk '{print $2}'
}

download_with_progress() {
    local url="$1"
    local output="$2"

    if ! command_exists curl || ! is_terminal; then
        download_file_simple "$url" "$output"
        return $?
    fi

    local content_length
    content_length=$(get_content_length "${url}")

    if [[ -z "${content_length}" ]] || [[ "${content_length}" -le 0 ]] 2>/dev/null; then
        download_file_simple "$url" "$output"
        return $?
    fi

    # Skip progress bar for small files (e.g. SHA256SUMS)
    if [[ "${content_length}" -lt 102400 ]] 2>/dev/null; then
        curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 "${url}" -o "${output}"
        return $?
    fi

    printf "\033[?25l" >&2
    print_progress 0 "${content_length}"

    curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 "${url}" -o "${output}" &
    ACTIVE_DOWNLOAD_PID=$!

    while kill -0 "${ACTIVE_DOWNLOAD_PID}" 2>/dev/null; do
        if [[ -f "${output}" ]]; then
            local file_size
            file_size=$(wc -c < "${output}" 2>/dev/null | tr -d ' ')
            if [[ -n "${file_size}" && "${file_size}" -gt 0 ]] 2>/dev/null; then
                print_progress "${file_size}" "${content_length}"
            fi
        fi
        sleep 1
    done

    wait "${ACTIVE_DOWNLOAD_PID}"
    local exit_code=$?
    ACTIVE_DOWNLOAD_PID=""
    printf "\033[?25h" >&2

    if [[ $exit_code -eq 0 ]]; then
        finish_progress
    else
        echo "" >&2
    fi
    return $exit_code
}

download_file_simple() {
    local url="$1"
    local destination="$2"

    if command_exists curl; then
        curl -fL --retry 2 --connect-timeout 15 --max-time 300 --progress-bar "${url}" -o "${destination}"
        return $?
    fi

    if command_exists wget; then
        local wget_args=(--tries=3 --timeout=15)
        if wget --help 2>&1 | grep -q -- '--read-timeout'; then
            wget_args+=(--read-timeout=300)
        fi
        if wget --help 2>&1 | grep -q -- '--progress'; then
            wget --progress=bar:force:noscroll "${wget_args[@]}" "${url}" -O "${destination}" &
            ACTIVE_DOWNLOAD_PID=$!
            wait "${ACTIVE_DOWNLOAD_PID}"
            local exit_code=$?
            ACTIVE_DOWNLOAD_PID=""
            return "${exit_code}"
        else
            wget "${wget_args[@]}" "${url}" -O "${destination}" &
            ACTIVE_DOWNLOAD_PID=$!
            wait "${ACTIVE_DOWNLOAD_PID}"
            local exit_code=$?
            ACTIVE_DOWNLOAD_PID=""
            return "${exit_code}"
        fi
    fi

    log_error "curl or wget is required to download the standalone archive."
    return 1
}

download_file() {
    local url="$1"
    local destination="$2"

    download_with_progress "${url}" "${destination}"
}

url_exists() {
    local url="$1"

    probe_url_available "${url}" 30
}

sha256_file() {
    local file_path="$1"

    if command_exists sha256sum; then
        LC_ALL=C LANG=C sha256sum "${file_path}" | awk '{print $1}'
        return 0
    fi

    if command_exists shasum; then
        LC_ALL=C LANG=C shasum -a 256 "${file_path}" | awk '{print $1}'
        return 0
    fi

    return 1
}

verify_checksum() {
    local archive_path="$1"
    local checksum_source="$2"
    local archive_name="$3"
    local checksum_file="${checksum_source}"
    local temp_checksum=""

    if [[ -z "${checksum_file}" ]]; then
        checksum_file="$(dirname "${archive_path}")/SHA256SUMS"
    elif [[ "${checksum_file}" == http://* || "${checksum_file}" == https://* ]]; then
        temp_checksum="$(mktemp)"
        if ! download_file "${checksum_file}" "${temp_checksum}"; then
            rm -f "${temp_checksum}"
            log_error "Could not download SHA256SUMS for checksum verification."
            return 1
        fi
        checksum_file="${temp_checksum}"
    fi

    if [[ ! -f "${checksum_file}" ]]; then
        rm -f "${temp_checksum}"
        log_error "SHA256SUMS not found at ${checksum_file}; cannot verify archive."
        return 1
    fi

    local expected
    expected=$(awk -v archive_name="${archive_name}" '
        {
            name = $2
            sub(/^\*/, "", name)
            if (name == archive_name) {
                print $1
                exit
            }
        }
    ' "${checksum_file}")
    if [[ -z "${expected}" ]]; then
        rm -f "${temp_checksum}"
        log_error "Checksum entry for ${archive_name} not found."
        return 1
    fi

    local actual
    if ! actual=$(sha256_file "${archive_path}"); then
        rm -f "${temp_checksum}"
        log_error "No SHA-256 utility found; cannot verify archive."
        return 1
    fi

    rm -f "${temp_checksum}"

    if [[ "${expected}" != "${actual}" ]]; then
        log_error "Checksum mismatch for ${archive_name}: expected ${expected}, got ${actual}."
        return 1
    fi
}

validate_archive_entry_path() {
    local entry="$1"
    entry="${entry//\\//}"

    while [[ "${entry}" == ./* ]]; do
        entry="${entry#./}"
    done

    # Reject entries containing CR/LF so a `..\r` or `..\n` entry cannot
    # bypass the literal `..` glob below.
    case "${entry}" in
        *$'\r'*|*$'\n'*)
            log_error "Archive contains unsafe path with control character: ${entry}"
            return 1
            ;;
    esac

    case "${entry}" in
        ""|/*|..|../*|*/..|*/../*)
            log_error "Archive contains unsafe path: ${entry:-<empty>}"
            return 1
            ;;
    esac
}

archive_contains_symlinks_or_hardlinks() {
    local archive_path="$1"

    case "${archive_path}" in
        *.zip)
            unzip -Z -v "${archive_path}" 2>/dev/null | grep -E 'Unix file attributes \(12[0-7]{4} octal\)' >/dev/null
            ;;
        *.tar.gz|*.tgz|*.tar.xz)
            tar -tvf "${archive_path}" 2>/dev/null | awk '$1 ~ /^[lh]/ { found=1 } END { exit found ? 0 : 1 }'
            ;;
        *)
            return 1
            ;;
    esac
}

validate_archive_contents() {
    local archive_path="$1"
    local entries
    local entry

    case "${archive_path}" in
        *.zip)
            if ! command_exists unzip; then
                log_error "unzip is required to inspect ${archive_path}."
                return 1
            fi
            if ! entries=$(unzip -Z1 "${archive_path}"); then
                log_error "Failed to inspect archive entries: ${archive_path}"
                return 1
            fi
            ;;
        *.tar.gz|*.tgz|*.tar.xz)
            if ! entries=$(tar -tf "${archive_path}"); then
                log_error "Failed to inspect archive entries: ${archive_path}"
                return 1
            fi
            ;;
        *)
            log_error "Unsupported archive format: ${archive_path}"
            return 1
            ;;
    esac

    if [[ -z "${entries}" ]]; then
        log_error "Archive is empty: ${archive_path}"
        return 1
    fi

    if archive_contains_symlinks_or_hardlinks "${archive_path}"; then
        log_error "Archive contains symlinks or hardlinks; refusing to install."
        return 1
    fi

    while IFS= read -r entry; do
        validate_archive_entry_path "${entry}" || return 1
    done <<< "${entries}"
}

extract_archive() {
    local archive_path="$1"
    local destination="$2"

    mkdir -p "${destination}" || return 1
    validate_archive_contents "${archive_path}" || return 1

    case "${archive_path}" in
        *.zip)
            if ! command_exists unzip; then
                log_error "unzip is required to extract ${archive_path}."
                return 1
            fi
            unzip -q "${archive_path}" -d "${destination}" || return 1
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "${archive_path}" -C "${destination}" || return 1
            ;;
        *.tar.xz)
            tar -xf "${archive_path}" -C "${destination}" || return 1
            ;;
        *)
            log_error "Unsupported archive format: ${archive_path}"
            return 1
            ;;
    esac

    local symlink_entry
    symlink_entry=$(find "${destination}" -type l -print | sed -n '1p')
    if [[ -n "${symlink_entry}" ]]; then
        log_error "Archive contains symlinks; refusing to install."
        return 1
    fi
}

ensure_managed_install_dir() {
    local install_dir="$1"

    if [[ ! -e "${install_dir}" ]]; then
        return 0
    fi

    if is_paradox_standalone_install_dir "${install_dir}"; then
        return 0
    fi

    local backup="${install_dir}.backup.$(date +%Y%m%dT%H%M%S 2>/dev/null || date +%Y%m%d%H%M%S)"
    log_warning "${install_dir} exists but is not a ParadoxLab standalone install."
    log_warning "Backing up to: ${backup}"
    if mv "${install_dir}" "${backup}"; then
        return 0
    fi

    log_error "Failed to back up ${install_dir}. Move or remove it manually, then rerun the installer."
    return 1
}

restore_stale_install_backup() {
    local old_install_dir="$1"
    local current_install_dir="$2"

    if [[ -e "${current_install_dir}" || ! -e "${old_install_dir}" ]]; then
        return 0
    fi

    log_warning "Found previous install backup without an active install: ${old_install_dir}"
    log_warning "Restoring backup to ${current_install_dir} before continuing."
    if mv "${old_install_dir}" "${current_install_dir}"; then
        return 0
    fi

    log_error "Failed to restore previous install from ${old_install_dir}."
    return 1
}

is_paradox_standalone_install_dir() {
    local install_dir="$1"
    local manifest_path="${install_dir}/manifest.json"

    [[ -f "${manifest_path}" ]] || return 1
    # Manifest format is produced by writeManifest in create-standalone-package.js.
    # Keep these grep checks in sync if that JSON layout changes.
    grep -Eq '"name"[[:space:]]*:[[:space:]]*"@paradoxlab/cli"' "${manifest_path}" 2>/dev/null || return 1
    grep -Eq '"target"[[:space:]]*:[[:space:]]*"linux-(arm64|x64)"' "${manifest_path}" 2>/dev/null || return 1
    [[ -f "${install_dir}/bin/paradox" && ! -L "${install_dir}/bin/paradox" && -x "${install_dir}/bin/paradox" ]] || return 1
    [[ -f "${install_dir}/node/bin/node" && ! -L "${install_dir}/node/bin/node" && -x "${install_dir}/node/bin/node" ]] || return 1
}

write_unix_wrapper() {
    local wrapper_path="$1"
    local paradox_bin="$2"
    local quoted_paradox_bin
    quoted_paradox_bin=$(shell_quote "${paradox_bin}")

    if ! cat > "${wrapper_path}" <<EOF
#!/usr/bin/env sh
exec ${quoted_paradox_bin} "\$@"
EOF
    then
        return 1
    fi
    chmod +x "${wrapper_path}"
}

install_standalone() {
    # Standalone mode is fail-closed: a missing owner release is an error.
    local target=""
    local archive_name=""
    local archive_path=""
    local checksum_source=""
    local temp_dir=""

    if [[ -n "${ARCHIVE_PATH}" ]]; then
        if ! target=$(detect_target); then
            log_error "No ParadoxLab standalone archive is available for this platform."
            return 1
        fi
        archive_path="${ARCHIVE_PATH}"
        archive_name="$(basename "${archive_path}")"
        if [[ ! -f "${archive_path}" ]]; then
            log_error "Standalone archive not found: ${archive_path}"
            return 1
        fi
    else
        if ! target=$(detect_target); then
            log_error "No ParadoxLab standalone archive is available for this platform."
            return 1
        fi
        local archive_extension
        archive_extension=$(archive_extension_for_target "${target}")
        archive_name="paradoxcli-${target}.${archive_extension}"
        local base_url
        if ! base_url=$(standalone_base_url); then
            log_error "Unable to resolve the configured ParadoxLab release endpoint."
            return 1
        fi
        local archive_url="${base_url}/${archive_name}"
        checksum_source="${base_url}/SHA256SUMS"
        temp_dir=$(mktemp -d)
        register_temp_dir "${temp_dir}"
        archive_path="${temp_dir}/${archive_name}"
        log_info "Downloading ${archive_name} from ${base_url}"
        if ! download_file "${archive_url}" "${archive_path}"; then
            rm -rf "${temp_dir}"
            log_error "Failed to download the ParadoxLab archive; automatic fallback is disabled."
            return 1
        fi
    fi

    if [[ -z "${temp_dir}" ]]; then
        temp_dir=$(mktemp -d)
        register_temp_dir "${temp_dir}"
    fi

    if ! verify_checksum "${archive_path}" "${checksum_source}" "${archive_name}"; then
        rm -rf "${temp_dir}"
        return 1
    fi

    local extract_dir="${temp_dir}/extract"
    if ! extract_archive "${archive_path}" "${extract_dir}"; then
        rm -rf "${temp_dir}"
        return 1
    fi

    if [[ ! -f "${extract_dir}/paradoxcli/bin/paradox" || -L "${extract_dir}/paradoxcli/bin/paradox" || ! -x "${extract_dir}/paradoxcli/bin/paradox" ]]; then
        log_error "Archive does not contain paradox/bin/paradox."
        rm -rf "${temp_dir}"
        return 1
    fi

    if [[ ! -f "${extract_dir}/paradoxcli/node/bin/node" || -L "${extract_dir}/paradoxcli/node/bin/node" || ! -x "${extract_dir}/paradoxcli/node/bin/node" ]]; then
        log_error "Archive does not contain executable paradox/node/bin/node."
        rm -rf "${temp_dir}"
        return 1
    fi

    mkdir -p "${INSTALL_LIB_PARENT}" "${INSTALL_BIN_DIR}" || {
        rm -rf "${temp_dir}"
        return 1
    }

    # Stage into .new and keep .old so failed upgrades can roll back.
    local new_install_dir="${INSTALL_LIB_DIR}.new"
    local old_install_dir="${INSTALL_LIB_DIR}.old"
    local wrapper_tmp="${INSTALL_BIN_DIR}/paradox.new"
    if ! ensure_managed_install_dir "${INSTALL_LIB_DIR}" ||
        ! ensure_managed_install_dir "${new_install_dir}" ||
        ! ensure_managed_install_dir "${old_install_dir}"; then
        rm -rf "${temp_dir}"
        return 1
    fi
    if ! restore_stale_install_backup "${old_install_dir}" "${INSTALL_LIB_DIR}"; then
        rm -rf "${temp_dir}"
        return 1
    fi
    if [[ -e "${old_install_dir}" ]]; then
        rm -rf "${old_install_dir}" || {
            rm -rf "${temp_dir}"
            log_error "Failed to remove stale install backup: ${old_install_dir}"
            return 1
        }
    fi
    rm -rf "${new_install_dir}" "${wrapper_tmp}"
    mv "${extract_dir}/paradoxcli" "${new_install_dir}"

    if ! write_unix_wrapper "${wrapper_tmp}" "${INSTALL_LIB_DIR}/bin/paradox"; then
        rm -rf "${temp_dir}" "${new_install_dir}" "${wrapper_tmp}"
        log_error "Failed to create paradox wrapper in ${INSTALL_BIN_DIR}."
        return 1
    fi

    # Suppress INT/TERM during the critical mv swap to avoid leaving
    # INSTALL_LIB_DIR absent if the user presses Ctrl+C between the two moves.
    trap '' INT TERM
    if [[ -e "${INSTALL_LIB_DIR}" ]]; then
        mv "${INSTALL_LIB_DIR}" "${old_install_dir}"
    fi

    if ! mv "${new_install_dir}" "${INSTALL_LIB_DIR}"; then
        if [[ -e "${old_install_dir}" ]]; then
            mv "${old_install_dir}" "${INSTALL_LIB_DIR}"
        fi
        trap 'restore_cursor >&2; kill_active_download; cleanup_temp_dirs; exit 130' INT
        trap 'restore_cursor >&2; kill_active_download; cleanup_temp_dirs; exit 143' TERM
        rm -rf "${temp_dir}" "${wrapper_tmp}"
        log_error "Failed to install standalone archive to ${INSTALL_LIB_DIR}."
        return 1
    fi
    trap 'restore_cursor >&2; kill_active_download; cleanup_temp_dirs; exit 130' INT
    trap 'restore_cursor >&2; kill_active_download; cleanup_temp_dirs; exit 143' TERM

    if ! mv -f "${wrapper_tmp}" "${INSTALL_BIN_DIR}/paradox"; then
        rm -rf "${INSTALL_LIB_DIR}" "${wrapper_tmp}"
        if [[ -e "${old_install_dir}" ]]; then
            mv "${old_install_dir}" "${INSTALL_LIB_DIR}"
        fi
        rm -rf "${temp_dir}"
        log_error "Failed to create paradox wrapper in ${INSTALL_BIN_DIR}."
        return 1
    fi

    rm -rf "${old_install_dir}"
    export PATH="${INSTALL_BIN_DIR}:${PATH}"

    create_source_json
    rm -rf "${temp_dir}"
}

npm_package_spec() {
    if [[ "${VERSION}" == "latest" ]]; then
        echo "@paradoxlab/cli@latest"
        return 0
    fi

    local npm_version="${VERSION#v}"
    echo "@paradoxlab/cli@${npm_version}"
}

install_npm() {
    require_node || return 1
    require_npm || return 1

    local package_spec
    package_spec=$(npm_package_spec)

    local install_cmd=(
        npm
        install
        -g
        "${package_spec}"
        --registry
        "${NPM_REGISTRY}"
    )

    if "${install_cmd[@]}"; then
        create_source_json
        return 0
    fi

    log_error "Failed to install. Try: npm install -g ${package_spec} --registry ${NPM_REGISTRY}"
    return 1
}

gradient_line() {
    local text="$1"
    local r1=$2 g1=$3 b1=$4
    local r2=$5 g2=$6 b2=$7
    local r3=$8 g3=$9 b3=${10}
    local len=${#text}
    [ "$len" -eq 0 ] && return
    if ! supports_truecolor; then
        printf "%b%s%b\n" "${BRAND_PURPLE}" "${text}" "${NC}"
        return
    fi
    local i=0
    local half=$(( len / 2 ))
    while [ $i -lt $len ]; do
        local char="${text:$i:1}"
        local r g b
        if [ $i -lt $half ]; then
            local t=$(( i * 1000 / half ))
            r=$(( (r1 * (1000 - t) + r2 * t) / 1000 ))
            g=$(( (g1 * (1000 - t) + g2 * t) / 1000 ))
            b=$(( (b1 * (1000 - t) + b2 * t) / 1000 ))
        else
            local t=$(( (i - half) * 1000 / (len - half) ))
            r=$(( (r2 * (1000 - t) + r3 * t) / 1000 ))
            g=$(( (g2 * (1000 - t) + g3 * t) / 1000 ))
            b=$(( (b2 * (1000 - t) + b3 * t) / 1000 ))
        fi
        if [ "$char" = " " ]; then
            printf " "
        else
            printf "\033[38;2;%d;%d;%dm%s" "$r" "$g" "$b" "$char"
        fi
        i=$(( i + 1 ))
    done
    printf "\033[0m\n"
}

print_logo() {
    # Per-character gradient matching CLI's ink-gradient rendering
    # Direction: #4796E4 (blue) → #847ACE (purple) → #C3677F (rose)
    gradient_line " ▄▄▄▄▄▄  ▄▄     ▄▄ ▄▄▄▄▄▄▄ ▄▄▄    ▄▄"  71 150 228  132 122 206  195 103 127
    gradient_line "██╔═══██╗██║    ██║██╔════╝████╗  ██║"  71 150 228  132 122 206  195 103 127
    gradient_line "██║   ██║██║ █╗ ██║█████╗  ██╔██╗ ██║"  71 150 228  132 122 206  195 103 127
    gradient_line "██║▄▄ ██║██║███╗██║██╔══╝  ██║╚██╗██║"  71 150 228  132 122 206  195 103 127
    gradient_line "╚██████╔╝╚███╔███╔╝███████╗██║ ╚████║"  71 150 228  132 122 206  195 103 127
    gradient_line " ╚══▀▀═╝  ╚══╝╚══╝ ╚══════╝╚═╝  ╚═══╝"  71 150 228  132 122 206  195 103 127
}

print_final_instructions() {
    local install_bin_dir="${1:-}"
    local install_dir="${2:-}"
    local install_method="${3:-standalone}"
    local installed_bin=""
    local standalone_uninstall_url="https://raw.githubusercontent.com/Damdiyal/paradox-cli/main/scripts/installation/uninstall-paradox-standalone.sh"
    if [[ -n "${install_bin_dir}" ]]; then
        installed_bin="${install_bin_dir}/paradox"
        export PATH="${install_bin_dir}:${PATH}"
    fi

    # Detect shadowing paradox executables
    local other_paradox_bins=""
    if [[ -n "${PRE_INSTALL_PARADOX_BINS:-}" ]]; then
        local saved_ifs="${IFS}"
        IFS=$'\n'
        local path
        for path in ${PRE_INSTALL_PARADOX_BINS}; do
            [[ -z "${path}" ]] && continue
            [[ -n "${installed_bin}" && "${path}" == "${installed_bin}" ]] && continue
            if [[ -z "${other_paradox_bins}" ]]; then
                other_paradox_bins="${path}"
            else
                other_paradox_bins="${other_paradox_bins}"$'\n'"${path}"
            fi
        done
        IFS="${saved_ifs}"
    fi

    if [[ -n "${install_bin_dir}" && "${NO_MODIFY_PATH:-0}" != "1" ]]; then
        PATH_UPDATE_APPLIED=0
        PATH_UPDATE_RC_FILE=""
        maybe_update_shell_path "${install_bin_dir}"
    fi

    local installed_version="unknown"
    if [[ -n "${installed_bin}" && -x "${installed_bin}" ]]; then
        installed_version=$("${installed_bin}" --version 2>/dev/null || echo "unknown")
    elif command_exists paradox; then
        installed_version=$(paradox --version 2>/dev/null || echo "unknown")
    fi

    # Display the rc file maybe_update_shell_path actually wrote to (e.g. bash
    # may fall back to ~/.bash_profile), so the success message and the reload
    # hint can never point at a different file than the one that was modified.
    local rc_name="${PATH_UPDATE_RC_FILE:-}"
    if [[ -n "${rc_name}" && -n "${HOME:-}" && "${rc_name}" == "${HOME}"/* ]]; then
        rc_name="~${rc_name#"${HOME}"}"
    fi
    if [[ "${PATH_UPDATE_APPLIED:-0}" == "1" && -n "${rc_name}" ]]; then
        echo -e "${MUTED}Successfully added${NC} paradox ${MUTED}to \$PATH in${NC} ${rc_name}"
    fi

    # The invoking shell keeps its original PATH (and possibly an older ParadoxLab
    # resolved from it) until the rc file is reloaded. Detect both cases and
    # tell the user exactly what to run instead of silently letting `paradox`
    # launch a stale version.
    local shell_reload_needed=0
    if [[ -n "${install_bin_dir}" ]]; then
        case ":${ORIGINAL_PATH}:" in
            *":${install_bin_dir}:"*) ;;
            *) shell_reload_needed=1 ;;
        esac
    fi
    if [[ -n "${other_paradox_bins}" ]]; then
        shell_reload_needed=1
        log_warning "Other paradox executables were found and may shadow the new install in this shell:"
        local shadow_path
        while IFS= read -r shadow_path; do
            [[ -z "${shadow_path}" ]] && continue
            printf '  %s\n' "${shadow_path}"
        done <<< "${other_paradox_bins}"
    fi

    local reload_cmd=""
    if [[ "${shell_reload_needed}" == "1" ]]; then
        if [[ "${PATH_UPDATE_APPLIED:-0}" == "1" && -n "${rc_name}" ]]; then
            reload_cmd="source ${rc_name}"
        elif [[ -n "${install_bin_dir}" ]]; then
            log_warning "Make sure ${install_bin_dir} comes first on your PATH, then open a new terminal."
        fi
    fi

    echo ""
    echo -e "${MUTED}ParadoxLab ${installed_version} installed successfully, to start:${NC}"
    echo ""
    if [[ -n "${reload_cmd}" ]]; then
        echo -e "${reload_cmd}  ${MUTED}# Load new PATH (or open a new terminal)${NC}"
    fi
    echo -e "cd <project>  ${MUTED}# Open directory${NC}"
    echo -e "paradox       ${MUTED}# Run command${NC}"
    echo ""
    echo -e "${MUTED}For more information visit ${NC}https://github.com/Damdiyal/paradox-cli"
    echo ""
}

main() {
    if [[ -z "${HOME:-}" ]]; then
        log_error "HOME is not set; cannot determine where to install ParadoxLab."
        exit 1
    fi

    # Discover all ParadoxLab executables on disk BEFORE we install, so the
    # just-installed binary doesn't pollute the search. We can't reliably
    # simulate the user's interactive shell PATH (some tools inject their
    # bin only under a tty), so we enumerate well-known per-tool bin
    # directories plus whatever bash inherited on PATH.
    PRE_INSTALL_PARADOX_BINS=$(
        {
            IFS=:
            for dir in $PATH; do
                [[ -z "${dir}" ]] && continue
                [[ -x "${dir}/paradox" ]] && echo "${dir}/paradox"
            done
            for candidate in \
                "${HOME}/.opencode/bin/paradox" \
                "${HOME}/.bun/bin/paradox" \
                "${HOME}/.cargo/bin/paradox" \
                "${HOME}/.deno/bin/paradox" \
                "${HOME}/.volta/bin/paradox" \
                "${HOME}/.fnm/bin/paradox" \
                "${HOME}/.local/bin/paradox" \
                "${HOME}/Library/pnpm/paradox" \
                "/usr/local/bin/paradox" \
                "/opt/homebrew/bin/paradox"; do
                [[ -x "${candidate}" ]] && echo "${candidate}"
            done
            if command_exists npm; then
                local npm_prefix
                npm_prefix=$(npm prefix -g 2>/dev/null || true)
                if [[ -n "${npm_prefix}" && -x "${npm_prefix}/bin/paradox" ]]; then
                    echo "${npm_prefix}/bin/paradox"
                fi
            fi
        } 2>/dev/null | sort -u
    )
    export PRE_INSTALL_PARADOX_BINS

    print_header

    case "${METHOD}" in
        standalone)
            if ! install_standalone; then
                log_error "Standalone install failed; no alternate source will be tried."
                exit 1
            fi
            print_final_instructions "${INSTALL_BIN_DIR}" "${INSTALL_LIB_DIR}" "standalone"
            ;;
        npm)
            install_npm
            print_final_instructions "$(get_npm_global_bin)" "$(get_npm_global_root)" "npm"
            ;;
    esac
}

main "$@"
