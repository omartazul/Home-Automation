# ATmega8A Home Automation Firmware (FV5.1.0)

This is the core microcontroller firmware for the Home Automation system. It runs on an ATmega8 or ATmega8A clocked at 16 MHz. It handles the real-time, hardware-critical tasks like phase-angle triac firing, zero-cross synchronization, and infrared decoding.

## Core Features
*   **Phase-Angle Triac Dimming**: Controls fan speed (levels 1-9) deterministically via hardware timers.
*   **Zero-Cross Synchronization**: Uses hardware interrupts (INT0) for precise AC wave timing.
*   **Watchdog & Auto-Recovery**: Monitors zero-cross signals and automatically restarts outputs if AC noise causes a sync loss.
*   **Infrared Control**: Hardware-level decoding of Sony SIRC-12 remote commands.
*   **State Persistence**: Direct EEPROM management to retain the power state, fan level, and light states across power outages.
*   **Structured Serial Protocol**: Communicates with the ESP-01S Wi-Fi bridge via a clean text protocol at 115200 baud.

## Pin Mapping

### Inputs
*   **Zero-Cross Detector**: `PD2` (INT0)
*   **IR Receiver (SIRC)**: `PB2` (Uses internal pull-up)

### Outputs
*   **Fan Triac Gate**: `PD3`
*   **Light 1 Relay**: `PC0`
*   **Light 2 Relay**: `PC1`
*   **Socket/Plug Relay**: `PC5`

### 7-Segment Display (Active-LOW)
*   Segment A: `PD7`
*   Segment B: `PB0`
*   Segment C: `PC2`
*   Segment D: `PC3`
*   Segment E: `PC4`
*   Segment F: `PD6`
*   Segment G: `PD5`

## Serial Protocol Reference
The ATmega communicates over standard UART (115200 baud). The ESP-01S bridge relies on this protocol.

### Commands (`SET:` / `GET:`)
*   `SET:PWR:ON` / `SET:PWR:OFF` - Master power toggle.
*   `SET:FAN:ON` / `SET:FAN:OFF` - Fan toggle.
*   `SET:FAN:SPD:<1-9>` - Set fan speed level.
*   `SET:LT1:ON` / `SET:LT1:OFF` - Light 1 toggle.
*   `SET:LT2:ON` / `SET:LT2:OFF` - Light 2 toggle.
*   `SET:PLG:ON` / `SET:PLG:OFF` - Socket plug toggle.
*   `SET:MINP:<0-100>` - Set the minimum conduction percentage for the fan triac.
*   `GET:STATUS` - Retrieve the complete machine state.
*   `GET:MINP` - Retrieve current minimum percentage.

### Responses
*   `OK:<DEVICE>:<STATE>` - Acknowledgment of a state change.
*   `ERR:PWR_OFF` - Command rejected because master power is off.
*   `ERR:INVALID` - Malformed or unrecognized command.
*   `STATUS:PWR=ON,FAN=ON,SPD=5,LT1=OFF,LT2=OFF,PLG=ON,MINP=5,FW=FV5.1.0` - Full state dump.

## Compilation & Flashing
1. **Target**: ATmega8 / ATmega8A
2. **Clock**: 16 MHz External Crystal (`F_CPU = 16000000UL`)
3. Ensure the fuse bits are set correctly for an external 16 MHz oscillator.
