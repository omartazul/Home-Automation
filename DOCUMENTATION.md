# 📚 System Documentation: Home Automation V5

This document details the internal architecture, communication protocols, and design decisions of the Home Automation V5 system.

## 1. System Architecture
The system is divided into three highly decoupled domains to ensure stability and responsiveness:
1. **Real-Time Controller (ATmega8A)**: Handles strict timing requirements. AC phase-angle dimming and zero-cross detection require microsecond precision.
2. **Network Gateway (ESP-01S)**: Handles heavy asynchronous network tasks (TCP/IP, HTTP, WebSockets) without blocking the ATmega.
3. **User Interface (Flutter App)**: Provides the control surface, hardware caching, and user interactions.

## 2. Communication Protocol (Serial)
The ESP-01S and ATmega8A communicate via a structured, line-buffered hardware UART protocol at `115200` baud.

### Supported ATmega Commands
| Command | Description |
|---|---|
| `SET:PWR:ON` / `OFF` | Master power toggle. |
| `SET:FAN:ON` / `OFF` | Fan toggle. |
| `SET:FAN:SPD:<1-9>` | Set fan speed level (1 is lowest, 9 is 100%). |
| `SET:LT1:ON` / `OFF` | Light 1 toggle. |
| `SET:LT2:ON` / `OFF` | Light 2 toggle. |
| `SET:PLG:ON` / `OFF` | Socket plug toggle. |
| `SET:MINP:<0-100>` | Adjust minimum conduction percentage for Triac. |
| `GET:STATUS` | Request a complete state dump. |

### Status Responses
The ATmega responds to actions and `GET:STATUS` queries with an atomic, parseable string:
`STATUS:PWR=ON,FAN=ON,SPD=5,LT1=OFF,LT2=OFF,PLG=ON,MINP=5,FW=FV5.1.0`

## 3. REST API & WebSockets (ESP-01S)
The ESP-01S caches the latest ATmega status to provide 0-latency responses to the Flutter app. It acts as an API gateway.

* **Authentication**: HTTP Basic Auth (`home:123456789`) required for mutating state.
* **mDNS Name**: `homeauto.local`

### Key Endpoints
* `GET /api/status`: Returns the cached state instantly as JSON.
* `POST /api/command`: Forwards a raw string (e.g., `{"cmd": "SET:FAN:SPD:5"}`) to the ATmega and awaits the UART response.
* `GET /api/wifi/scan`: Returns nearby SSIDs and RSSI values for app provisioning.
* `POST /api/wifi`: Submits Wi-Fi credentials to switch the ESP from AP to STA mode.
* `POST /api/update`: Accepts a `multipart/form-data` `.bin` file for OTA firmware flashing.

### WebSockets
* **URI**: `ws://<device_ip>:81`
* The ESP-01S broadcasts state changes over WebSockets instantly whenever a physical remote (IR) or API call alters the ATmega's state, updating the Flutter UI in real-time.

## 4. Phase-Angle Dimming Logic
To achieve flicker-free fan dimming, the ATmega utilizes the following pipeline:
1. **Zero-Cross Interrupt (INT0)**: Triggers precisely when the AC sine wave crosses 0V.
2. **Hardware Timer (Timer1)**: Calculates the delay based on the `FAN_POWER_PERCENT` lookup table (`DELAY_FROM_PERCENT`).
3. **Gate Pulse**: Fires the Triac gate for `200us` exactly at the target phase angle, cutting the AC wave to deliver partial power.

### Watchdog & Auto-Recovery
If AC noise causes missing zero-crosses (desynchronization), the ATmega firmware has an internal Watchdog that temporarily disables the Triac to prevent erratic or dangerous AC firing. It will attempt an automatic recovery after 30 seconds to restore connectivity without user intervention.
