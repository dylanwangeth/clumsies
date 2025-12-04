#!/bin/sh
set -e

REPO="dylanwangeth/clumsies"
INSTALL_DIR="$HOME/.clumsies"
BIN_DIR="$INSTALL_DIR/bin"

# Colors (Zig orange theme)
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
ORANGE='\033[38;5;214m'
GREEN='\033[32m'
RED='\033[31m'
CYAN='\033[36m'

info() { printf "  %b→%b %s\n" "$ORANGE" "$RESET" "$1"; }
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

main() {
    printf "\n%b%bInstalling %bclumsies%b%b...%b\n\n" "$BOLD" "" "$ORANGE" "$RESET" "$BOLD" "$RESET"

    PLATFORM=$(detect_platform)
    printf "  %b→%b Detected platform: %b%s%b\n" "$ORANGE" "$RESET" "$ORANGE" "$PLATFORM" "$RESET"

    printf "  %b→%b Creating %b%s/%b\n" "$ORANGE" "$RESET" "$ORANGE" "$INSTALL_DIR" "$RESET"
    mkdir -p "$BIN_DIR"
    mkdir -p "$INSTALL_DIR/registry"

    info "Downloading binary..."
    DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/clumsies-$PLATFORM"

    if command -v curl > /dev/null; then
        curl -fsSL "$DOWNLOAD_URL" -o "$BIN_DIR/clumsies"
    elif command -v wget > /dev/null; then
        wget -q "$DOWNLOAD_URL" -O "$BIN_DIR/clumsies"
    else
        error "curl or wget required"
    fi

    chmod +x "$BIN_DIR/clumsies"

    RC_FILE=$(detect_shell_rc)
    PATH_LINE='export PATH="$HOME/.clumsies/bin:$PATH"'

    if ! grep -q ".clumsies/bin" "$RC_FILE" 2>/dev/null; then
        printf "  %b→%b Configuring PATH in %b%s%b\n" "$ORANGE" "$RESET" "$ORANGE" "$RC_FILE" "$RESET"
        echo "" >> "$RC_FILE"
        echo "# clumsies" >> "$RC_FILE"
        echo "$PATH_LINE" >> "$RC_FILE"
    else
        info "PATH already configured"
    fi

    printf "\n"
    success "clumsies installed successfully!"
    printf "\nRun %bsource $RC_FILE%b or restart your terminal, then try:\n\n" "$CYAN" "$RESET"
    printf "    %bclumsies search%b\n" "$CYAN" "$RESET"
    printf "    %bclumsies use solocc%b\n\n" "$CYAN" "$RESET"
}

main
