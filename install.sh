#!/bin/sh
set -e

REPO="lilhammerfun/clumsies"
INSTALL_DIR="$HOME/.clumsies"
BIN_DIR="$INSTALL_DIR/bin"

# Colors
BOLD='\033[1m'
RESET='\033[0m'
ORANGE='\033[38;5;214m'
GREEN='\033[32m'
RED='\033[31m'
CYAN='\033[36m'

info() { printf "%b→%b %s\n" "$ORANGE" "$RESET" "$1"; }
success() { printf "%b%b✓%b %s\n" "$BOLD" "$ORANGE" "$RESET" "$1"; }
error() { printf "%b%bError:%b %s\n" "$BOLD" "$RED" "$RESET" "$1" >&2; exit 1; }

detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64|amd64) ARCH="x86_64" ;;
        arm64|aarch64) ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    case "$OS" in
        darwin|linux) ;;
        *) error "Unsupported OS: $OS" ;;
    esac

    echo "${OS}-${ARCH}"
}

detect_shell_rc() {
    case "$SHELL" in
        */zsh) echo "$HOME/.zshrc" ;;
        */fish) echo "$HOME/.config/fish/config.fish" ;;
        *) echo "$HOME/.bashrc" ;;
    esac
}

download() {
    url="$1"
    output="$2"
    if command -v curl > /dev/null; then
        curl -fsSL "$url" -o "$output"
    elif command -v wget > /dev/null; then
        wget -q "$url" -O "$output"
    else
        error "curl or wget required"
    fi
}

verify_checksum() {
    file="$1"
    expected="$2"

    if command -v sha256sum > /dev/null; then
        actual=$(sha256sum "$file" | cut -d' ' -f1)
    elif command -v shasum > /dev/null; then
        actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    else
        printf "%b!%b Warning: Cannot verify checksum\n" "$ORANGE" "$RESET"
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        error "Checksum verification failed!"
    fi
}

get_latest_tag() {
    API_URL="https://api.github.com/repos/$REPO/releases?per_page=1"
    if command -v curl > /dev/null; then
        TAG=$(curl -fsSL "$API_URL" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    elif command -v wget > /dev/null; then
        TAG=$(wget -qO- "$API_URL" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
    else
        error "curl or wget required"
    fi

    if [ -z "$TAG" ]; then
        error "Failed to fetch latest release tag"
    fi

    echo "$TAG"
}

main() {
    printf "%b%bInstalling %bclumsies%b%b...%b\n" "$BOLD" "" "$ORANGE" "$RESET" "$BOLD" "$RESET"

    PLATFORM=$(detect_platform)
    BINARY_NAME="clumsies-$PLATFORM"
    printf "%b→%b Detected platform: %b%s%b\n" "$ORANGE" "$RESET" "$ORANGE" "$PLATFORM" "$RESET"

    info "Fetching latest release..."
    TAG=$(get_latest_tag)
    printf "%b→%b Latest release: %b%s%b\n" "$ORANGE" "$RESET" "$ORANGE" "$TAG" "$RESET"

    printf "%b→%b Creating %b%s%b\n" "$ORANGE" "$RESET" "$ORANGE" "$INSTALL_DIR" "$RESET"
    mkdir -p "$BIN_DIR"

    # Download checksums
    info "Downloading checksums..."
    CHECKSUMS_URL="https://github.com/$REPO/releases/download/$TAG/checksums.txt"
    CHECKSUMS_FILE=$(mktemp)
    download "$CHECKSUMS_URL" "$CHECKSUMS_FILE"

    EXPECTED_CHECKSUM=$(grep "$BINARY_NAME" "$CHECKSUMS_FILE" | cut -d' ' -f1)
    if [ -z "$EXPECTED_CHECKSUM" ]; then
        rm -f "$CHECKSUMS_FILE"
        error "Checksum not found for $BINARY_NAME"
    fi
    rm -f "$CHECKSUMS_FILE"

    # Download binary
    info "Downloading binary..."
    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/$BINARY_NAME"
    TEMP_BINARY=$(mktemp)
    download "$DOWNLOAD_URL" "$TEMP_BINARY"

    # Verify checksum
    info "Verifying checksum..."
    verify_checksum "$TEMP_BINARY" "$EXPECTED_CHECKSUM"
    success "Checksum verified"

    # Install binary
    mv "$TEMP_BINARY" "$BIN_DIR/clumsies"
    chmod +x "$BIN_DIR/clumsies"

    RC_FILE=$(detect_shell_rc)
    PATH_LINE='export PATH="$HOME/.clumsies/bin:$PATH"'

    if ! grep -q ".clumsies/bin" "$RC_FILE" 2>/dev/null; then
        printf "%b→%b Configuring PATH in %b%s%b\n" "$ORANGE" "$RESET" "$ORANGE" "$RC_FILE" "$RESET"
        echo "" >> "$RC_FILE"
        echo "# clumsies" >> "$RC_FILE"
        echo "$PATH_LINE" >> "$RC_FILE"
    else
        info "PATH already configured"
    fi

    success "clumsies installed successfully!"
    printf "Run %bsource $RC_FILE%b or restart your terminal, then try:\n" "$CYAN" "$RESET"
    printf "    %bclumsies --help%b\n" "$CYAN" "$RESET"
    printf "    %bclumsies config set registry <git-url>%b\n" "$CYAN" "$RESET"
    printf "    %bclumsies ls%b\n" "$CYAN" "$RESET"
}

main
