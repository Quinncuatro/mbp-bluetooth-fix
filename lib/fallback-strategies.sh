#!/bin/bash
#
# fallback-strategies.sh - Alternative recovery methods for Bluetooth audio quality
#
# This script contains multiple fallback strategies when the primary
# BluetoothConnector approach fails to restore A2DP audio quality.
#

set -euo pipefail

# Configuration constants
readonly DEVICE_MAC="0C:E0:E4:86:0B:06"
readonly DEVICE_NAME="PLT_BBTPRO"

# Logging functions (reused from main script)
log_info() { printf "[INFO] %s\n" "$*"; }
log_success() { printf "\e[32m[SUCCESS]\e[0m %s\n" "$*"; }
log_warn() { printf "\e[33m[WARN]\e[0m %s\n" "$*" >&2; }
log_error() { printf "\e[31m[ERROR]\e[0m %s\n" "$*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf "\e[36m[DEBUG]\e[0m %s\n" "$*" >&2; }

# Fallback Strategy 1: Audio Device Cycling
cycle_audio_devices() {
    log_info "Attempting audio device cycling fallback..."
    
    # Check if audio-devices CLI is available
    if ! command -v audio-devices >/dev/null 2>&1; then
        log_error "audio-devices CLI not available"
        return 1
    fi
    
    # Get current audio device
    local current_device
    current_device=$(audio-devices output get 2>/dev/null) || {
        log_error "Failed to get current audio device"
        return 1
    }
    
    log_info "Current device: $current_device"
    
    # Switch to built-in speakers
    if audio-devices output set "Built-in Output" 2>/dev/null; then
        log_info "Switched to Built-in Output"
        sleep 2
        
        # Switch back to target Bluetooth device
        if audio-devices output set "$DEVICE_NAME" 2>/dev/null; then
            log_success "Successfully cycled back to $DEVICE_NAME"
            return 0
        else
            log_error "Failed to switch back to $DEVICE_NAME"
            # Attempt to restore original device
            audio-devices output set "$current_device" 2>/dev/null || true
            return 1
        fi
    else
        log_error "Failed to switch to Built-in Output"
        return 1
    fi
}

# Fallback Strategy 2: Alternative Bluetooth Tool (blueutil)
use_blueutil_fallback() {
    log_info "Attempting blueutil fallback..."
    
    if ! command -v blueutil >/dev/null 2>&1; then
        log_debug "blueutil not available"
        return 1
    fi
    
    # Disconnect using blueutil
    if blueutil --disconnect "$DEVICE_MAC" 2>/dev/null; then
        log_info "Device disconnected via blueutil"
        sleep 3
        
        # Reconnect using blueutil
        if blueutil --connect "$DEVICE_MAC" 2>/dev/null; then
            log_success "Device reconnected via blueutil"
            sleep 2
            return 0
        fi
    fi
    
    return 1
}

# Fallback Strategy 3: AppleScript Bluetooth Control
applescript_bluetooth_control() {
    log_info "Attempting AppleScript Bluetooth control..."
    
    # AppleScript to toggle Bluetooth device
    local script="
    tell application \"System Preferences\"
        reveal pane \"Bluetooth\"
        delay 2
    end tell
    
    tell application \"System Events\"
        tell process \"System Preferences\"
            -- Find and click the device
            try
                click button \"Disconnect\" of row \"$DEVICE_NAME\" of table 1 of scroll area 1 of group 1 of tab group 1 of window 1
                delay 3
                click button \"Connect\" of row \"$DEVICE_NAME\" of table 1 of scroll area 1 of group 1 of tab group 1 of window 1
            end try
        end tell
    end tell
    
    tell application \"System Preferences\" to quit
    "
    
    if osascript -e "$script" 2>/dev/null; then
        log_success "AppleScript Bluetooth control completed"
        return 0
    else
        log_error "AppleScript Bluetooth control failed"
        return 1
    fi
}

# Fallback Strategy 4: Audio System Reset
restart_core_audio() {
    log_info "Attempting Core Audio restart..."
    
    # Kill Core Audio daemon (will auto-restart)
    if sudo pkill coreaudiod 2>/dev/null; then
        log_info "Core Audio daemon restarted"
        sleep 3  # Wait for restart
        return 0
    else
        log_warn "Could not restart Core Audio daemon"
        return 1
    fi
}

# Fallback Strategy 5: Bluetooth Preference Reset
reset_bluetooth_preferences() {
    log_info "Attempting Bluetooth preference reset..."
    
    # Backup and reset Bluetooth preferences (requires user confirmation)
    local bt_plist="$HOME/Library/Preferences/com.apple.Bluetooth.plist"
    
    if [[ -f "$bt_plist" ]]; then
        log_info "Backing up Bluetooth preferences..."
        cp "$bt_plist" "${bt_plist}.backup.$(date +%s)" 2>/dev/null || {
            log_error "Could not backup Bluetooth preferences"
            return 1
        }
        
        # Remove device-specific entries (this is aggressive)
        log_warn "This will remove all Bluetooth pairings!"
        read -p "Continue? (y/N): " -n 1 -r
        echo
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm "$bt_plist" 2>/dev/null
            log_info "Bluetooth preferences reset (restart required)"
            return 0
        else
            log_info "Bluetooth preference reset cancelled"
            return 1
        fi
    fi
    
    return 1
}

# Fallback Strategy 6: Manual Recovery Guidance
show_manual_recovery_menu() {
    cat << EOF

Automated recovery failed. Please try these manual steps:

1. HARDWARE RESET
   - Turn off your $DEVICE_NAME headphones
   - Wait 10 seconds
   - Turn them back on
   - Wait for reconnection

2. BLUETOOTH MENU
   - Click Bluetooth icon in menu bar
   - Find "$DEVICE_NAME"
   - Click "Disconnect"
   - Wait 5 seconds
   - Click "Connect"

3. SYSTEM PREFERENCES
   - Open System Preferences → Bluetooth
   - Find "$DEVICE_NAME" in device list
   - Click "Disconnect" button
   - Wait for status to change
   - Click "Connect" button

4. AUDIO PREFERENCES
   - Open System Preferences → Sound
   - Click "Output" tab
   - Select a different device temporarily
   - Wait 2 seconds
   - Select "$DEVICE_NAME" again

5. COMPLETE BLUETOOTH RESET (last resort)
   - Go to System Preferences → Bluetooth
   - Remove/Forget "$DEVICE_NAME"
   - Re-pair the device from scratch

EOF

    read -p "Press Enter after trying manual recovery, or 'q' to quit: " -r
    if [[ $REPLY == "q" ]]; then
        return 1
    fi
    
    # Test if manual recovery worked
    log_info "Testing audio device after manual recovery..."
    if check_device_connected && verify_audio_restoration; then
        log_success "Manual recovery appears successful!"
        return 0
    else
        log_warn "Device status unclear after manual recovery"
        return 1
    fi
}

# Helper function: Check device connection (from main script)
check_device_connected() {
    local output
    if ! command -v BluetoothConnector >/dev/null 2>&1; then
        return 1
    fi
    
    output=$(BluetoothConnector --status "$DEVICE_MAC" 2>/dev/null) || return 1
    [[ $output == *"connected"* ]]
}

# Helper function: Verify audio restoration (simplified)
verify_audio_restoration() {
    # Check if device appears in audio output list
    if command -v audio-devices >/dev/null 2>&1; then
        if audio-devices list 2>/dev/null | grep -q "$DEVICE_NAME"; then
            return 0
        fi
    fi
    
    # Fallback: Check Bluetooth profile information
    if system_profiler SPBluetoothDataType 2>/dev/null | grep -A 10 "$DEVICE_NAME" | grep -q "A2DP"; then
        return 0
    fi
    
    # Basic connectivity check as last resort
    if check_device_connected; then
        return 0
    fi
    
    return 1
}

# Comprehensive fallback orchestration
execute_all_fallbacks() {
    local strategies=(
        "cycle_audio_devices"
        "use_blueutil_fallback"
        "applescript_bluetooth_control"
        "restart_core_audio"
        "show_manual_recovery_menu"
    )
    
    log_info "Primary strategy failed. Trying fallback strategies..."
    
    for strategy in "${strategies[@]}"; do
        log_info "Attempting: $strategy"
        
        if "$strategy"; then
            log_success "Fallback strategy '$strategy' succeeded!"
            return 0
        else
            log_warn "Fallback strategy '$strategy' failed"
        fi
        
        # Brief pause between strategies
        sleep 1
    done
    
    log_error "All fallback strategies failed"
    return 1
}

# Intelligent fallback selection
select_best_fallback() {
    # Check what tools are available
    local available_tools=()
    
    command -v audio-devices >/dev/null 2>&1 && available_tools+=("audio-cycling")
    command -v blueutil >/dev/null 2>&1 && available_tools+=("blueutil")
    [[ $(id -u) -eq 0 ]] && available_tools+=("system-restart")
    
    # Select based on available tools and failure context
    if [[ " ${available_tools[*]} " == *" audio-cycling "* ]]; then
        log_info "Using audio device cycling (safest fallback)"
        cycle_audio_devices
    elif [[ " ${available_tools[*]} " == *" blueutil "* ]]; then
        log_info "Using blueutil alternative"
        use_blueutil_fallback
    else
        log_info "No automated fallbacks available, using manual guidance"
        show_manual_recovery_menu
    fi
}

# Command line interface for fallback strategies
main() {
    local command="${1:-help}"
    
    case "$command" in
        "audio-cycling")
            cycle_audio_devices
            ;;
        "blueutil")
            use_blueutil_fallback
            ;;
        "applescript")
            applescript_bluetooth_control
            ;;
        "core-audio-restart")
            restart_core_audio
            ;;
        "manual")
            show_manual_recovery_menu
            ;;
        "all")
            execute_all_fallbacks
            ;;
        "smart")
            select_best_fallback
            ;;
        "help"|*)
            cat << EOF
Fallback Strategies for Bluetooth Audio Quality Fix

USAGE:
    $0 <strategy>

STRATEGIES:
    audio-cycling        Cycle through audio output devices
    blueutil            Use alternative blueutil command
    applescript         Use AppleScript GUI automation
    core-audio-restart  Restart Core Audio daemon (requires sudo)
    manual              Interactive manual recovery guidance
    all                 Try all strategies in sequence
    smart               Automatically select best available strategy
    help                Show this help message

EXAMPLES:
    $0 audio-cycling     # Try audio device cycling
    $0 smart             # Auto-select best strategy
    $0 all               # Try all strategies

EOF
            ;;
    esac
}

# Execute main if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi