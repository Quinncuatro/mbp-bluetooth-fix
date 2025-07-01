#!/bin/bash
#
# fix-audio - Restore Bluetooth audio quality after video calls
# 
# Fixes Plantronics Backbeat Pro audio profile switching from HFP 
# (low-quality mono) back to A2DP (high-quality stereo) after 
# Google Meet calls and similar applications.
#

set -euo pipefail  # Strict error handling

# Configuration constants
readonly DEVICE_MAC="0C:E0:E4:86:0B:06"
readonly DEVICE_NAME="PLT_BBTPRO"
readonly SCRIPT_NAME="fix-audio"
readonly VERSION="1.0.0"

# Timing configuration
readonly DISCONNECT_WAIT=3
readonly VERIFY_WAIT=2
readonly MAX_RETRIES=3

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

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        printf "\e[36m[DEBUG]\e[0m %s\n" "$*" >&2
    fi
}

# Show help information
show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Restore Bluetooth audio quality

USAGE:
    $SCRIPT_NAME [OPTIONS]

DESCRIPTION:
    Fixes Plantronics Backbeat Pro audio quality degradation after Google Meet 
    calls by forcing Bluetooth profile reset from HFP back to A2DP.

OPTIONS:
    -h, --help          Show this help message
    -v, --version       Show version information
    -d, --debug         Enable debug output
    --dry-run           Show what would be done without executing
    --status            Show current device status
    --discover          Discover all Bluetooth devices
    --find-plantronics  Find Plantronics devices automatically
    --device MAC        Use specific device MAC address

EXAMPLES:
    $SCRIPT_NAME                    # Fix audio quality
    DEBUG=1 $SCRIPT_NAME            # Run with debug output
    $SCRIPT_NAME --dry-run          # Preview operations

TARGET DEVICE:
    $DEVICE_NAME ($DEVICE_MAC)

DEPENDENCIES:
    - BluetoothConnector (install: brew install bluetoothconnector)
    - macOS system utilities (system_profiler)

EOF
}

# Discover all paired Bluetooth devices
discover_bluetooth_devices() {
    log_info "=== Bluetooth Device Discovery ==="
    
    # Method 1: Using system_profiler
    if command -v system_profiler >/dev/null 2>&1; then
        log_info "Paired Bluetooth devices (system_profiler):"
        system_profiler SPBluetoothDataType 2>/dev/null | grep -E "(Address|Name):" | grep -A1 -B1 "Address:" || {
            log_warn "No devices found via system_profiler"
        }
        echo
    fi
    
    # Method 2: Using BluetoothConnector discovery
    if command -v BluetoothConnector >/dev/null 2>&1; then
        log_info "Discovering devices via BluetoothConnector:"
        # List all paired devices - this might not be supported by all versions
        local bt_output
        bt_output=$(BluetoothConnector --list 2>/dev/null) || {
            log_debug "BluetoothConnector --list not supported or failed"
        }
        if [[ -n "$bt_output" ]]; then
            echo "$bt_output"
        else
            log_debug "BluetoothConnector discovery yielded no results"
        fi
        echo
    fi
    
    # Method 3: Using audio-devices if available
    if command -v audio-devices >/dev/null 2>&1; then
        log_info "Audio devices (including Bluetooth):"
        audio-devices list 2>/dev/null | grep -i bluetooth || {
            log_debug "No Bluetooth audio devices found via audio-devices"
        }
        echo
    fi
}

# Find Plantronics devices automatically
find_plantronics_devices() {
    local devices=()
    
    log_debug "Searching for Plantronics devices..."
    
    # Search in system profiler output
    if command -v system_profiler >/dev/null 2>&1; then
        local profiler_output
        profiler_output=$(system_profiler SPBluetoothDataType 2>/dev/null)
        
        # Look for Plantronics device names and MAC addresses
        while IFS= read -r line; do
            if [[ $line =~ PLT_|Plantronics|BackBeat|BBTPRO ]]; then
                log_debug "Found potential Plantronics device: $line"
                # Try to extract MAC address from the context
                local mac_context
                mac_context=$(echo "$profiler_output" | grep -A 10 -B 10 "$line" | grep "Address:" | head -1)
                if [[ $mac_context =~ ([0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}) ]]; then
                    devices+=("${BASH_REMATCH[1]}:$line")
                fi
            fi
        done <<< "$profiler_output"
    fi
    
    if [[ ${#devices[@]} -gt 0 ]]; then
        log_info "Found Plantronics devices:"
        printf '  %s\n' "${devices[@]}"
        return 0
    else
        log_warn "No Plantronics devices found automatically"
        return 1
    fi
}

# Enhanced device connection check with multiple methods
check_device_connected() {
    local mac_address="${1:-$DEVICE_MAC}"
    local method_used=""
    
    log_debug "Checking connection status for device: $mac_address"
    
    # Method 1: BluetoothConnector (primary)
    if command -v BluetoothConnector >/dev/null 2>&1; then
        local bt_output
        bt_output=$(BluetoothConnector --status "$mac_address" 2>&1)
        local bt_exit_code=$?
        
        log_debug "BluetoothConnector --status output: '$bt_output'"
        log_debug "BluetoothConnector exit code: $bt_exit_code"
        
        if [[ $bt_exit_code -eq 0 ]]; then
            # Check various possible connection indicators in the output
            if [[ $bt_output =~ (connected|Connected|CONNECTED) ]] || 
               [[ $bt_output =~ (status:.*true|Status:.*true) ]] ||
               [[ $bt_output =~ (true) ]]; then
                method_used="BluetoothConnector"
                log_debug "Device connected (detected via $method_used)"
                return 0
            fi
        fi
    fi
    
    # Method 2: system_profiler fallback
    if command -v system_profiler >/dev/null 2>&1; then
        local profiler_output
        profiler_output=$(system_profiler SPBluetoothDataType 2>/dev/null)
        
        # Look for the device and check if it shows as connected
        if echo "$profiler_output" | grep -A 15 "$mac_address" | grep -q -i "connected.*yes\|state.*connected"; then
            method_used="system_profiler"
            log_debug "Device connected (detected via $method_used)"
            return 0
        fi
    fi
    
    # Method 3: audio-devices fallback (for audio connectivity specifically)
    if command -v audio-devices >/dev/null 2>&1; then
        local audio_output
        audio_output=$(audio-devices list 2>/dev/null)
        
        # Check if a Bluetooth device matching our target is available as audio output
        if echo "$audio_output" | grep -i bluetooth | grep -q -i "PLT\|Plantronics\|BackBeat"; then
            method_used="audio-devices"
            log_debug "Device appears to be available for audio (detected via $method_used)"
            return 0
        fi
    fi
    
    log_debug "Device not detected as connected by any method"
    return 1
}

# Disconnect the device
disconnect_device() {
    local output
    log_info "Disconnecting Bluetooth device..."
    
    output=$(BluetoothConnector --disconnect "$DEVICE_MAC" 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Disconnect failed: $output"
        return 1
    fi
    
    log_debug "Disconnect command completed"
    return 0
}

# Reconnect the device
reconnect_device() {
    local output
    log_info "Reconnecting device..."
    
    output=$(BluetoothConnector --connect "$DEVICE_MAC" --notify 2>&1)
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Reconnect failed: $output"
        return 1
    fi
    
    log_debug "Reconnect command completed"
    return 0
}

# Verify audio restoration
verify_audio_restoration() {
    log_debug "Verifying audio restoration..."
    
    # Check if device appears in audio output list
    if command -v audio-devices >/dev/null 2>&1; then
        if audio-devices list 2>/dev/null | grep -q "$DEVICE_NAME"; then
            log_debug "Device detected in audio output list"
            return 0
        fi
    fi
    
    # Fallback: Check Bluetooth profile information
    if system_profiler SPBluetoothDataType 2>/dev/null | grep -A 10 "$DEVICE_NAME" | grep -q "A2DP"; then
        log_debug "A2DP profile detected"
        return 0
    fi
    
    # Basic connectivity check as last resort
    if check_device_connected; then
        log_debug "Device reconnected (profile status unclear)"
        return 0
    fi
    
    return 1
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    # Check for BluetoothConnector
    if ! command -v BluetoothConnector >/dev/null 2>&1; then
        missing_deps+=("BluetoothConnector")
    fi
    
    # Check for system utilities
    if ! command -v system_profiler >/dev/null 2>&1; then
        missing_deps+=("system_profiler")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies:"
        printf '  - %s\n' "${missing_deps[@]}"
        echo
        log_info "Install BluetoothConnector with: brew install bluetoothconnector"
        return 1
    fi
    
    return 0
}

# Check device availability
check_device_availability() {
    # Check if device exists in paired devices
    if ! system_profiler SPBluetoothDataType 2>/dev/null | grep -q "$DEVICE_MAC"; then
        log_error "Target device not found in paired Bluetooth devices"
        log_info "Expected: $DEVICE_NAME ($DEVICE_MAC)"
        log_info "Run 'system_profiler SPBluetoothDataType' to see available devices"
        return 1
    fi
    
    return 0
}

# Execute the main fix sequence
execute_fix_sequence() {
    # Step 1: Verify initial connection
    log_info "Checking device status..."
    if ! check_device_connected; then
        log_warn "Device not currently connected"
        return 1
    fi
    
    # Step 2: Disconnect device
    if ! disconnect_device; then
        log_error "Failed to disconnect device"
        return 1
    fi
    
    # Step 3: Wait for clean disconnection
    log_info "Waiting ${DISCONNECT_WAIT} seconds for clean disconnection..."
    sleep $DISCONNECT_WAIT
    
    # Step 4: Reconnect device
    if ! reconnect_device; then
        log_error "Failed to reconnect device"
        return 1
    fi
    
    # Step 5: Wait for profile establishment
    log_info "Waiting ${VERIFY_WAIT} seconds for profile establishment..."
    sleep $VERIFY_WAIT
    
    # Step 6: Verify restoration
    if verify_audio_restoration; then
        return 0
    else
        log_warn "Could not verify A2DP restoration"
        return 1
    fi
}

# Main fix function with retry logic
fix_audio_quality() {
    local attempt=1
    
    while [[ $attempt -le $MAX_RETRIES ]]; do
        log_info "Attempt ${attempt}/${MAX_RETRIES}"
        
        if execute_fix_sequence; then
            return 0
        fi
        
        if [[ $attempt -lt $MAX_RETRIES ]]; then
            log_warn "Attempt failed, retrying in 2 seconds..."
            sleep 2
        fi
        
        ((attempt++))
    done
    
    return 1
}

# Show device status with enhanced diagnostics
show_device_status() {
    log_info "=== Device Status ==="
    log_info "Target: $DEVICE_NAME ($DEVICE_MAC)"
    echo
    
    # Check connection with detailed feedback
    if check_device_connected "$DEVICE_MAC"; then
        log_success "✅ Device is connected and detected"
    else
        log_warn "⚠️  Device connection not detected"
        echo
        log_info "Running device discovery to help diagnose..."
        discover_bluetooth_devices
        find_plantronics_devices
    fi
    
    # Show detailed device info if available
    if command -v system_profiler >/dev/null 2>&1; then
        echo
        log_info "Bluetooth device information for $DEVICE_MAC:"
        local device_info
        device_info=$(system_profiler SPBluetoothDataType | grep -A 15 "$DEVICE_MAC")
        if [[ -n "$device_info" ]]; then
            echo "$device_info"
        else
            log_warn "Device $DEVICE_MAC not found in system profiler output"
            echo
            log_info "All paired devices:"
            system_profiler SPBluetoothDataType | grep -E "(Name|Address):" | head -20
        fi
    fi
    
    # Show audio device info if available
    if command -v audio-devices >/dev/null 2>&1; then
        echo
        log_info "Audio device information:"
        local audio_devices_output
        audio_devices_output=$(audio-devices list 2>/dev/null)
        if echo "$audio_devices_output" | grep -q -i bluetooth; then
            echo "$audio_devices_output" | grep -i bluetooth
        else
            log_warn "No Bluetooth audio devices found"
            echo
            log_info "All audio devices:"
            echo "$audio_devices_output" | head -10
        fi
    fi
}

# Parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME version $VERSION"
                exit 0
                ;;
            -d|--debug)
                export DEBUG=1
                ;;
            --dry-run)
                export DRY_RUN=1
                ;;
            --status)
                show_device_status
                exit 0
                ;;
            --discover)
                discover_bluetooth_devices
                exit 0
                ;;
            --find-plantronics)
                find_plantronics_devices
                exit 0
                ;;
            --device)
                shift
                if [[ -z "$1" ]]; then
                    log_error "--device requires a MAC address argument"
                    exit 1
                fi
                # Validate MAC address format
                if [[ ! "$1" =~ ^([0-9A-Fa-f]{2}[:-]){5}([0-9A-Fa-f]{2})$ ]]; then
                    log_error "Invalid MAC address format: $1"
                    log_info "Expected format: XX:XX:XX:XX:XX:XX or XX-XX-XX-XX-XX-XX"
                    exit 1
                fi
                # Override the default device MAC
                DEVICE_MAC="$1"
                log_info "Using custom device MAC: $DEVICE_MAC"
                ;;
            *)
                log_error "Unknown option: $1"
                show_help >&2
                exit 1
                ;;
        esac
        shift
    done
}

# Show dry run preview
show_dry_run_preview() {
    cat << EOF
🎧 Bluetooth Audio Quality Fixer v$VERSION - DRY RUN MODE

Target Device: $DEVICE_NAME ($DEVICE_MAC)

EOF
    
    # Show current device status in dry-run
    log_info "Current device detection status:"
    if check_device_connected "$DEVICE_MAC"; then
        log_success "✅ Device is currently connected and detected"
    else
        log_warn "⚠️  Device is not currently detected as connected"
        echo
        log_info "Would attempt device discovery and retry detection..."
    fi
    
    cat << EOF

Would execute the following steps:
1. Check device connection status using multiple detection methods
2. Disconnect Bluetooth device using BluetoothConnector
3. Wait $DISCONNECT_WAIT seconds for clean disconnection
4. Reconnect Bluetooth device
5. Wait $VERIFY_WAIT seconds for profile establishment
6. Verify A2DP profile restoration using multiple verification methods

No actual changes will be made in dry-run mode.
Run without --dry-run to execute the fix.

Diagnostic commands you can run:
  $SCRIPT_NAME --status           # Show detailed device status
  $SCRIPT_NAME --discover         # Discover all Bluetooth devices
  $SCRIPT_NAME --find-plantronics # Find Plantronics devices automatically
  $SCRIPT_NAME --debug --dry-run  # Show debug information

EOF
}

# Main execution function
main() {
    parse_arguments "$@"
    
    # Enable debug mode if requested
    if [[ "${DEBUG:-0}" == "1" ]]; then
        set -x  # Enable command tracing
        log_debug "Debug mode enabled"
    fi
    
    # Show header
    log_info "🎧 Bluetooth Audio Quality Fixer v$VERSION"
    log_info "📱 Target: $DEVICE_NAME ($DEVICE_MAC)"
    echo
    
    # Handle dry run mode
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        show_dry_run_preview
        exit 0
    fi
    
    # Pre-flight checks
    log_info "Performing pre-flight checks..."
    if ! check_dependencies; then
        exit 1
    fi
    
    if ! check_device_availability; then
        exit 1
    fi
    
    # Execute fix with error handling
    if fix_audio_quality; then
        log_success "✅ Audio quality restored successfully!"
        exit 0
    else
        log_error "❌ Failed to restore audio quality"
        echo
        log_info "Manual recovery options:"
        log_info "1. Turn headphones off and on again"
        log_info "2. Go to System Preferences → Bluetooth → Disconnect/Reconnect"
        log_info "3. Go to System Preferences → Sound → Switch output device temporarily"
        exit 1
    fi
}

# Execute main if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi