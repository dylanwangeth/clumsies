#!/bin/sh
set -e

REPO="dylanwangeth/clumsies"
INSTALL_DIR="$HOME/.clumsies"
BIN_DIR="$INSTALL_DIR/bin"

info() { printf "  → %s\n" "$1"; }
success() { printf "\033[0;32m✓\033[0m %s\n" "$1"; }
error() { printf "\033[0;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

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
    echo "Installing clumsies..."
    echo

    PLATFORM=$(detect_platform)
    info "Detecting platform... $PLATFORM"

    info "Creating $INSTALL_DIR/"
    mkdir -p "$BIN_DIR"
    mkdir -p "$INSTALL_DIR/registry"

    info "Downloading clumsies..."
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
        info "Configuring PATH in $RC_FILE"
        echo "" >> "$RC_FILE"
        echo "# clumsies" >> "$RC_FILE"
        echo "$PATH_LINE" >> "$RC_FILE"
    else
        info "PATH already configured"
    fi

    echo
    success "clumsies installed successfully!"
    echo
    echo "Run 'source $RC_FILE' or restart your terminal, then try:"
    echo
    echo "    clumsies search"
    echo "    clumsies use solocc"
    echo
}

main
