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

info() { printf "  ${ORANGE}→${RESET} %s\n" "$1"; }
success() { printf "${BOLD}${ORANGE}✓${RESET} %s\n" "$1"; }
error() { printf "${BOLD}${RED}Error:${RESET} %s\n" "$1" >&2; exit 1; }

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
    printf "\n${BOLD}Installing ${ORANGE}clumsies${RESET}${BOLD}...${RESET}\n\n"

    PLATFORM=$(detect_platform)
    info "Detected platform: ${BOLD}$PLATFORM${RESET}"

    info "Creating ${BOLD}$INSTALL_DIR/${RESET}"
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
        info "Configuring PATH in ${BOLD}$RC_FILE${RESET}"
        echo "" >> "$RC_FILE"
        echo "# clumsies" >> "$RC_FILE"
        echo "$PATH_LINE" >> "$RC_FILE"
    else
        info "PATH already configured"
    fi

    printf "\n"
    success "${BOLD}clumsies installed successfully!${RESET}"
    printf "\nRun ${CYAN}source $RC_FILE${RESET} or restart your terminal, then try:\n\n"
    printf "    ${CYAN}clumsies search${RESET}\n"
    printf "    ${CYAN}clumsies use solocc${RESET}\n\n"
}

main
