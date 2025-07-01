#!/bin/bash
#
# install.sh - Installation script for Bluetooth Audio Quality Fixer
#
# This script installs all dependencies and sets up the fix-audio command
# for system-wide use on macOS.
#

set -euo pipefail

# Configuration
readonly SCRIPT_NAME="Bluetooth Audio Quality Fixer Installer"
readonly VERSION="1.0.0"
readonly INSTALL_DIR="/usr/local/bin"
readonly SCRIPT_SOURCE="$(dirname "$0")/fix-audio.sh"
readonly SCRIPT_TARGET="$INSTALL_DIR/fix-audio"

# Logging functions
log_info() {
    printf "[INFO] %s\n" "$*"
}

log_success() {
    printf "\e[32m[SUCCESS]\e[0m %s\n" "$*"
}

log_warn() {
    printf "\e[33m[WARN]\e[0m %s\n" "$*" >&2
}

log_error() {
    printf "\e[31m[ERROR]\e[0m %s\n" "$*" >&2
}

# Check if running on macOS
check_macos() {
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This installer is designed for macOS only"
        log_info "Current system: $(uname -s)"
        return 1
    fi
    
    log_info "Running on macOS $(sw_vers -productVersion)"
    return 0
}

# Check if Homebrew is installed
check_homebrew() {
    if ! command -v brew >/dev/null 2>&1; then
        log_warn "Homebrew not found"
        return 1
    else
        log_info "Homebrew found: $(brew --version | head -1)"
        return 0
    fi
}

# Install Homebrew
install_homebrew() {
    log_info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    
    # Add Homebrew to PATH for this session
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f "/usr/local/bin/brew" ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    
    log_success "Homebrew installed successfully"
}

# Install BluetoothConnector
install_bluetooth_connector() {
    if command -v BluetoothConnector >/dev/null 2>&1; then
        log_info "BluetoothConnector already installed"
        return 0
    fi
    
    log_info "Installing BluetoothConnector..."
    brew install bluetoothconnector
    
    if command -v BluetoothConnector >/dev/null 2>&1; then
        log_success "BluetoothConnector installed successfully"
        return 0
    else
        log_error "BluetoothConnector installation failed"
        return 1
    fi
}

# Install optional audio device manager
install_audio_devices() {
    if command -v audio-devices >/dev/null 2>&1; then
        log_info "audio-devices already installed"
        return 0
    fi
    
    if command -v npm >/dev/null 2>&1; then
        log_info "Installing @spotxyz/macos-audio-devices..."
        npm install -g @spotxyz/macos-audio-devices
        
        if command -v audio-devices >/dev/null 2>&1; then
            log_success "audio-devices installed successfully"
        else
            log_warn "audio-devices installation may have failed (optional)"
        fi
    else
        log_info "npm not available, skipping audio-devices installation (optional)"
    fi
}

# Install optional blueutil
install_blueutil() {
    if command -v blueutil >/dev/null 2>&1; then
        log_info "blueutil already installed"
        return 0
    fi
    
    log_info "Installing blueutil..."
    brew install blueutil
    
    if command -v blueutil >/dev/null 2>&1; then
        log_success "blueutil installed successfully"
    else
        log_warn "blueutil installation failed (optional)"
    fi
}

# Install the fix-audio script
install_fix_audio_script() {
    # Check if source script exists
    if [[ ! -f "$SCRIPT_SOURCE" ]]; then
        log_error "Source script not found: $SCRIPT_SOURCE"
        return 1
    fi
    
    # Check if target already exists
    if [[ -f "$SCRIPT_TARGET" ]]; then
        log_warn "fix-audio already installed at $SCRIPT_TARGET"
        read -p "Overwrite existing installation? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            return 1
        fi
    fi
    
    # Copy script to target location
    log_info "Installing fix-audio to $SCRIPT_TARGET..."
    
    if cp "$SCRIPT_SOURCE" "$SCRIPT_TARGET" 2>/dev/null; then
        chmod +x "$SCRIPT_TARGET"
        log_success "fix-audio installed successfully"
    else
        log_warn "Permission denied. Trying with sudo..."
        sudo cp "$SCRIPT_SOURCE" "$SCRIPT_TARGET"
        sudo chmod +x "$SCRIPT_TARGET"
        log_success "fix-audio installed successfully (with sudo)"
    fi
}

# Verify installation
verify_installation() {
    log_info "Verifying installation..."
    
    # Check fix-audio command
    if command -v fix-audio >/dev/null 2>&1; then
        log_success "fix-audio command available"
        fix-audio --version
    else
        log_error "fix-audio command not found in PATH"
        return 1
    fi
    
    # Check dependencies
    log_info "Checking dependencies..."
    
    if command -v BluetoothConnector >/dev/null 2>&1; then
        log_success "BluetoothConnector: OK"
    else
        log_error "BluetoothConnector: Missing (REQUIRED)"
        return 1
    fi
    
    if command -v system_profiler >/dev/null 2>&1; then
        log_success "system_profiler: OK"
    else
        log_error "system_profiler: Missing (REQUIRED)"
        return 1
    fi
    
    # Check optional dependencies
    if command -v audio-devices >/dev/null 2>&1; then
        log_success "audio-devices: OK (optional)"
    else
        log_info "audio-devices: Not available (optional)"
    fi
    
    if command -v blueutil >/dev/null 2>&1; then
        log_success "blueutil: OK (optional)"
    else
        log_info "blueutil: Not available (optional)"
    fi
    
    return 0
}

# Show post-installation instructions
show_post_install() {
    cat << EOF

🎉 Installation Complete!

The fix-audio command is now available system-wide.

USAGE:
    fix-audio                    # Fix audio quality after video calls
    fix-audio --help             # Show detailed help
    fix-audio --dry-run          # Preview what would be done
    fix-audio --status           # Check current device status

NEXT STEPS:
1. Make sure your Plantronics Backbeat Pro headphones are paired
2. Join a Google Meet call to trigger the audio quality issue
3. End the call and run 'fix-audio' to restore high-quality audio

TROUBLESHOOTING:
- Run 'fix-audio --status' to check device connectivity
- Use 'fix-audio --debug' for detailed execution information
- See the README for additional troubleshooting tips

TARGET DEVICE: PLT_BBTPRO (0C:E0:E4:86:0B:06)

Happy audio fixing! 🎧

EOF
}

# Handle command line options
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                cat << EOF
$SCRIPT_NAME v$VERSION

USAGE:
    ./install.sh [OPTIONS]

OPTIONS:
    --help              Show this help message
    --uninstall         Remove fix-audio and dependencies
    --dependencies-only Install only dependencies (not the script)
    --script-only       Install only the script (skip dependencies)

DESCRIPTION:
    Installs the Bluetooth Audio Quality Fixer and all required dependencies
    on macOS systems. The fix-audio command will be available system-wide
    after installation.

EOF
                exit 0
                ;;
            --uninstall)
                uninstall_everything
                exit 0
                ;;
            --dependencies-only)
                DEPENDENCIES_ONLY=1
                ;;
            --script-only)
                SCRIPT_ONLY=1
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
        shift
    done
}

# Uninstall everything
uninstall_everything() {
    log_info "Uninstalling Bluetooth Audio Quality Fixer..."
    
    # Remove script
    if [[ -f "$SCRIPT_TARGET" ]]; then
        rm "$SCRIPT_TARGET" 2>/dev/null || sudo rm "$SCRIPT_TARGET"
        log_success "fix-audio script removed"
    fi
    
    # Note about dependencies
    cat << EOF

Dependencies were not automatically removed:
- BluetoothConnector (brew uninstall bluetoothconnector)
- audio-devices (npm uninstall -g @spotxyz/macos-audio-devices)
- blueutil (brew uninstall blueutil)

Remove these manually if you no longer need them.

EOF
}

# Main installation flow
main() {
    parse_arguments "$@"
    
    log_info "=== $SCRIPT_NAME v$VERSION ==="
    echo
    
    # System checks
    if ! check_macos; then
        log_error "Installation failed: Unsupported system"
        exit 1
    fi
    
    # Skip script installation if dependencies-only
    if [[ "${DEPENDENCIES_ONLY:-0}" == "1" ]]; then
        log_info "Installing dependencies only..."
    elif [[ "${SCRIPT_ONLY:-0}" == "1" ]]; then
        log_info "Installing script only..."
        install_fix_audio_script
        verify_installation
        show_post_install
        exit 0
    else
        log_info "Installing complete solution..."
    fi
    
    # Install Homebrew if needed
    if ! check_homebrew; then
        install_homebrew
    fi
    
    # Install dependencies
    install_bluetooth_connector
    install_audio_devices
    install_blueutil
    
    # Install script unless dependencies-only
    if [[ "${DEPENDENCIES_ONLY:-0}" != "1" ]]; then
        install_fix_audio_script
    fi
    
    # Verify installation
    if [[ "${DEPENDENCIES_ONLY:-0}" != "1" ]]; then
        verify_installation
        show_post_install
    else
        log_success "Dependencies installed successfully!"
        log_info "Run './install.sh --script-only' to install the fix-audio command"
    fi
}

# Execute main function
main "$@"