# ESP-01S Wi-Fi to Serial Bridge

This firmware runs on an ESP8266 (ESP-01S) module and acts as a REST API gateway and Wi-Fi bridge for the ATmega8A microcontroller. 

## Core Features
*   **REST API Gateway**: Exposes HTTP endpoints for the Flutter mobile app to control the ATmega hardware.
*   **Optimized Caching**: Drains the ATmega serial output in the background and caches the hardware state in memory. API queries (`GET /api/status`) return instantly from the ESP's cache without incurring UART round-trip latency.
*   **Wi-Fi Provisioning**: Falls back to an Access Point (AP) mode if it cannot connect to a router, allowing users to provide credentials via a web portal.
*   **mDNS Support**: Broadcasts itself as `homeauto.local` on the network, so the app doesn't need to know its dynamic IP address.
*   **Over-The-Air (OTA) Updates**: Supports flashing new firmware directly over Wi-Fi without needing USB.
*   **State Persistence**: Saves Wi-Fi credentials and device identity strings to EEPROM.

## Pin Mapping
*   **Serial TX / RX**: Connected to the ATmega8A hardware UART.
*   **LED**: `GPIO2` (Active LOW) - Flashes during connection phases.

## REST API Reference

All endpoints accept and return JSON. HTTP Basic Auth (`home:123456789`) is required for command and update endpoints.

### Informational & Setup
*   `GET /` - HTML Setup portal (used in AP mode).
*   `GET /api/wifi/scan` - Returns an array of visible Wi-Fi networks (SSID, RSSI, security).
*   `POST /api/wifi` - Submit `{"ssid": "...", "pass": "..."}` to connect to a network.
*   `GET /api/info` - Returns diagnostic info (IP, MAC, mode, heap, uptime).
*   `GET /api/device-name` - Returns `{"name": "HomeAuto_XXX"}`.
*   `POST /api/device-name` - Set a new device name.

### Control & Status
*   `GET /api/status` - Returns the real-time cached state of the ATmega8A (e.g., `{"ok":true, "pwr":"ON", "fan":"ON", "spd":"5", ...}`). **Instantaneous response**.
*   `POST /api/command` - Forwards a raw command to the ATmega8A (e.g., `{"cmd": "SET:FAN:SPD:5"}`). Returns the response.
*   `POST /api/factory-reset` - Clears EEPROM and reboots into AP mode.

### OTA Update
*   `POST /api/update` - Send a `multipart/form-data` request with a `.bin` file to re-flash the ESP-01S firmware over the network.

## Compilation & Flashing
1. **Board**: Generic ESP8266 Module (or ESP-01S)
2. **Flash Size**: 1MB (FS: 64KB, OTA: ~470KB)
3. **Dependencies**: `ArduinoJson` (v7+)
4. Build the binary using Arduino IDE or `arduino-cli`, and upload either via serial (for the first time) or over the network using the OTA endpoint.
