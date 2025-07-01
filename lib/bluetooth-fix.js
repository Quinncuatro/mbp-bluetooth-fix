#!/usr/bin/env node

/**
 * bluetooth-fix.js - Advanced Node.js implementation for Bluetooth audio quality fix
 * 
 * Provides enhanced error handling, structured logging, and comprehensive
 * fallback strategies for fixing Plantronics Backbeat Pro audio quality
 * issues after Google Meet calls.
 */

const { promisify } = require('util');
const { exec } = require('child_process');
const execAsync = promisify(exec);

class BluetoothAudioFixer {
    constructor(options = {}) {
        this.deviceMAC = options.deviceMAC || '0C:E0:E4:86:0B:06';
        this.deviceName = options.deviceName || 'PLT_BBTPRO';
        this.disconnectWait = options.disconnectWait || 3000; // 3 seconds
        this.verifyWait = options.verifyWait || 2000;         // 2 seconds
        this.maxRetries = options.maxRetries || 3;
        this.verbose = options.verbose || false;
        this.dryRun = options.dryRun || false;
    }

    /**
     * Execute a system command with enhanced error handling
     */
    async executeCommand(command, options = {}) {
        const defaultOptions = {
            timeout: 10000, // 10 second timeout
            encoding: 'utf8',
            maxBuffer: 1024 * 1024 // 1MB buffer
        };

        const execOptions = { ...defaultOptions, ...options };

        try {
            if (this.dryRun) {
                this.log(`[DRY RUN] Would execute: ${command}`);
                return {
                    success: true,
                    stdout: 'dry-run-output',
                    stderr: '',
                    command
                };
            }

            this.log(`Executing: ${command}`, 'debug');
            const { stdout, stderr } = await execAsync(command, execOptions);
            
            return {
                success: true,
                stdout: stdout.trim(),
                stderr: stderr.trim(),
                command
            };
        } catch (error) {
            return this.handleCommandError(error, command);
        }
    }

    /**
     * Handle command execution errors with detailed analysis
     */
    handleCommandError(error, command) {
        const errorInfo = {
            success: false,
            command,
            exitCode: error.code,
            signal: error.signal,
            stdout: error.stdout?.trim() || '',
            stderr: error.stderr?.trim() || '',
            message: error.message
        };

        // Categorize error types
        if (error.code === 'ENOENT') {
            errorInfo.category = 'COMMAND_NOT_FOUND';
            errorInfo.userMessage = 'Required command not found or not in PATH';
        } else if (error.signal === 'SIGTERM' || error.signal === 'SIGKILL') {
            errorInfo.category = 'TIMEOUT';
            errorInfo.userMessage = 'Command timed out';
        } else if (error.code !== 0) {
            errorInfo.category = 'EXECUTION_FAILED';
            errorInfo.userMessage = 'Command execution failed';
        }

        this.log(`Command failed: ${JSON.stringify(errorInfo, null, 2)}`, 'debug');
        return errorInfo;
    }

    /**
     * Check if the target device is currently connected
     */
    async checkDeviceStatus() {
        this.log('Checking device connection status...');
        
        const result = await this.executeCommand(
            `BluetoothConnector --status ${this.deviceMAC}`
        );

        if (!result.success) {
            throw new Error(`Failed to check device status: ${result.userMessage || result.stderr}`);
        }

        // Parse BluetoothConnector output
        const isConnected = result.stdout.includes('connected');
        const isAvailable = !result.stdout.includes('not found');

        return {
            connected: isConnected,
            available: isAvailable,
            rawOutput: result.stdout
        };
    }

    /**
     * Wait for device to reach expected connection state
     */
    async waitForDeviceState(expectedState, maxWaitTime = 10000) {
        const startTime = Date.now();
        
        while (Date.now() - startTime < maxWaitTime) {
            try {
                const status = await this.checkDeviceStatus();
                
                if (status.connected === expectedState) {
                    return true;
                }
            } catch (error) {
                this.log(`Error checking device state: ${error.message}`, 'debug');
            }
            
            // Wait 500ms before checking again
            await this.sleep(500);
        }
        
        return false; // Timeout
    }

    /**
     * Gracefully disconnect the Bluetooth device
     */
    async disconnectDevice() {
        this.log('Initiating device disconnection...');
        
        // First verify device is connected
        const status = await this.checkDeviceStatus();
        if (!status.connected) {
            this.log('Device already disconnected');
            return { success: true, alreadyDisconnected: true };
        }

        // Execute disconnect command
        const result = await this.executeCommand(
            `BluetoothConnector --disconnect ${this.deviceMAC}`
        );

        if (!result.success) {
            throw new Error(`Disconnect failed: ${result.userMessage || result.stderr}`);
        }

        // Wait for clean disconnection
        this.log(`Waiting ${this.disconnectWait}ms for clean disconnection...`);
        await this.sleep(this.disconnectWait);

        // Verify disconnection
        const disconnected = await this.waitForDeviceState(false, 5000);
        if (!disconnected && !this.dryRun) {
            throw new Error('Device failed to disconnect within timeout period');
        }

        this.log('Device successfully disconnected');
        return { success: true };
    }

    /**
     * Reconnect the Bluetooth device
     */
    async reconnectDevice() {
        this.log('Initiating device reconnection...');
        
        // Ensure device is available for connection
        const status = await this.checkDeviceStatus();
        if (!status.available && !this.dryRun) {
            throw new Error('Device not available for connection (powered off or out of range)');
        }

        // Execute connect command with notification
        const result = await this.executeCommand(
            `BluetoothConnector --connect ${this.deviceMAC} --notify`
        );

        if (!result.success) {
            throw new Error(`Reconnection failed: ${result.userMessage || result.stderr}`);
        }

        // Wait for connection establishment
        this.log('Waiting for connection establishment...');
        const connected = await this.waitForDeviceState(true, 10000);
        
        if (!connected && !this.dryRun) {
            throw new Error('Device failed to connect within timeout period');
        }

        // Additional wait for profile negotiation
        this.log(`Waiting ${this.verifyWait}ms for profile negotiation...`);
        await this.sleep(this.verifyWait);

        this.log('Device successfully reconnected');
        return { success: true };
    }

    /**
     * Verify A2DP audio profile restoration
     */
    async verifyAudioRestoration() {
        this.log('Verifying audio profile restoration...');
        
        // Check if device appears in audio devices
        const audioCheck = await this.executeCommand(
            'audio-devices list | grep PLT_BBTPRO'
        );

        if (!audioCheck.success) {
            this.log('Warning: Device not detected in audio device list', 'warn');
        }

        // Check Bluetooth profile information
        const profileCheck = await this.executeCommand(
            `system_profiler SPBluetoothDataType | grep -A 10 "${this.deviceName}"`
        );

        if (profileCheck.success) {
            const hasA2DP = profileCheck.stdout.includes('A2DP');
            const hasHFP = profileCheck.stdout.includes('HFP');
            
            this.log(`Profile status - A2DP: ${hasA2DP}, HFP: ${hasHFP}`, 'debug');
            
            return {
                audioDeviceDetected: audioCheck.success,
                a2dpActive: hasA2DP,
                hfpAvailable: hasHFP,
                profileInfo: profileCheck.stdout
            };
        }

        // Fallback verification
        this.log('Using fallback verification method', 'debug');
        return { audioDeviceDetected: false, verified: false };
    }

    /**
     * Execute the complete fix workflow
     */
    async fixAudioQuality() {
        try {
            this.log('=== Starting Bluetooth Audio Quality Fix ===');
            
            // Step 1: Initial device status check
            await this.checkDeviceStatus();
            
            // Step 2: Disconnect device
            await this.disconnectDevice();
            
            // Step 3: Reconnect device
            await this.reconnectDevice();
            
            // Step 4: Verify audio restoration
            const verification = await this.verifyAudioRestoration();
            
            // Step 5: Final status report
            if (verification.a2dpActive || this.dryRun) {
                this.log('✅ Audio quality successfully restored!', 'success');
                return { success: true, verification };
            } else {
                this.log('⚠️  Audio reconnected but A2DP status unclear', 'warn');
                return { success: true, warning: 'Profile verification incomplete', verification };
            }
            
        } catch (error) {
            this.log(`❌ Fix failed: ${error.message}`, 'error');
            return { 
                success: false, 
                error: error.message,
                stack: this.verbose ? error.stack : undefined
            };
        }
    }

    /**
     * Audio device cycling fallback strategy
     */
    async fallbackAudioDeviceCycling() {
        this.log('Attempting audio device cycling fallback...');
        
        try {
            // Check if audio-devices is available
            const checkCmd = await this.executeCommand('which audio-devices');
            if (!checkCmd.success) {
                throw new Error('audio-devices command not available');
            }

            // Get current audio device
            const currentDevice = await this.executeCommand('audio-devices output get');
            if (!currentDevice.success) {
                throw new Error('Failed to get current audio device');
            }

            this.log(`Current audio device: ${currentDevice.stdout}`);

            // Switch to built-in speakers
            const switchToBuiltin = await this.executeCommand('audio-devices output set "Built-in Output"');
            if (!switchToBuiltin.success) {
                throw new Error('Failed to switch to built-in output');
            }

            this.log('Switched to Built-in Output');
            await this.sleep(2000); // Wait 2 seconds

            // Switch back to Bluetooth device
            const switchBack = await this.executeCommand(`audio-devices output set "${this.deviceName}"`);
            if (!switchBack.success) {
                // Try to restore original device
                await this.executeCommand(`audio-devices output set "${currentDevice.stdout}"`);
                throw new Error('Failed to switch back to Bluetooth device');
            }

            this.log('Successfully cycled back to Bluetooth device');
            return { success: true, method: 'audio-device-cycling' };

        } catch (error) {
            this.log(`Audio device cycling failed: ${error.message}`, 'error');
            return { success: false, error: error.message };
        }
    }

    /**
     * Execute fix with fallback strategies
     */
    async fixWithFallbacks() {
        // Primary strategy: BluetoothConnector
        let result = await this.fixAudioQuality();
        
        if (result.success) {
            return result;
        }

        this.log('Primary strategy failed, trying fallback strategies...');

        // Fallback 1: Audio device cycling
        const fallbackResult = await this.fallbackAudioDeviceCycling();
        if (fallbackResult.success) {
            this.log('Fallback strategy successful!', 'success');
            return { success: true, method: 'fallback', details: fallbackResult };
        }

        // All strategies failed
        return {
            success: false,
            error: 'All strategies failed',
            primaryError: result.error,
            fallbackError: fallbackResult.error
        };
    }

    /**
     * Utility: Sleep for specified milliseconds
     */
    sleep(ms) {
        return new Promise(resolve => setTimeout(resolve, ms));
    }

    /**
     * Logging with different levels
     */
    log(message, level = 'info') {
        const timestamp = new Date().toISOString();
        const prefix = `[${timestamp}]`;
        
        switch (level) {
            case 'success':
                console.log(`\x1b[32m${prefix} ${message}\x1b[0m`);
                break;
            case 'warn':
                console.warn(`\x1b[33m${prefix} ${message}\x1b[0m`);
                break;
            case 'error':
                console.error(`\x1b[31m${prefix} ${message}\x1b[0m`);
                break;
            case 'debug':
                if (this.verbose) {
                    console.log(`\x1b[36m${prefix} [DEBUG] ${message}\x1b[0m`);
                }
                break;
            default:
                console.log(`${prefix} ${message}`);
        }
    }
}

/**
 * CLI interface for the Node.js implementation
 */
async function main() {
    const args = process.argv.slice(2);
    
    // Parse command line arguments
    const options = {
        verbose: args.includes('--verbose') || args.includes('-v'),
        dryRun: args.includes('--dry-run'),
        help: args.includes('--help') || args.includes('-h'),
        fallbacks: args.includes('--with-fallbacks')
    };

    if (options.help) {
        console.log(`
🎧 Bluetooth Audio Quality Fixer (Node.js Advanced Implementation)

USAGE:
    node bluetooth-fix.js [OPTIONS]

OPTIONS:
    --verbose, -v       Enable verbose debug output
    --dry-run          Show what would be done without executing
    --with-fallbacks   Enable fallback strategies if primary method fails
    --help, -h         Show this help message

DESCRIPTION:
    Advanced Node.js implementation with enhanced error handling,
    structured logging, and multiple fallback strategies.

TARGET DEVICE: PLT_BBTPRO (0C:E0:E4:86:0B:06)

EXAMPLES:
    node bluetooth-fix.js                    # Basic fix
    node bluetooth-fix.js --verbose          # Verbose output
    node bluetooth-fix.js --with-fallbacks   # Use fallback strategies
    node bluetooth-fix.js --dry-run          # Preview mode
        `);
        process.exit(0);
    }

    const fixer = new BluetoothAudioFixer(options);
    
    console.log('🎧 Bluetooth Audio Quality Fixer (Node.js Advanced)');
    console.log(`📱 Target Device: ${fixer.deviceName} (${fixer.deviceMAC})`);
    console.log('');
    
    let result;
    if (options.fallbacks) {
        result = await fixer.fixWithFallbacks();
    } else {
        result = await fixer.fixAudioQuality();
    }
    
    if (result.success) {
        console.log('\n✨ Operation completed successfully!');
        if (result.method) {
            console.log(`Method used: ${result.method}`);
        }
        process.exit(0);
    } else {
        console.error('\n💥 Operation failed:', result.error);
        if (options.verbose && result.stack) {
            console.error('Stack trace:', result.stack);
        }
        process.exit(1);
    }
}

// Execute if run directly
if (require.main === module) {
    main().catch(error => {
        console.error('Unexpected error:', error);
        process.exit(1);
    });
}

module.exports = BluetoothAudioFixer;