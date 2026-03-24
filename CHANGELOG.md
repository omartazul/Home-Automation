# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [5.1.0] - 2026-03-24

### Added
- **Flutter App**: Full Smart Home Dashboard UI with zero-cross caching.
- **ESP-01S Gateway**: Optimized 0-latency REST API responses, WebSocket broadcasts, and OTA fallback logic.
- **ATmega8A Firmware**: Phase-Angle Triac dimming (levels 1-9) for ceiling fans.
- **Hardware Integrations**: Sony SIRC-12 remote IR decoding, Zero-cross hardware interrupts, state persistence on EEPROM.
- **Documentation**: Comprehensive `README.md`, deep-dive `DOCUMENTATION.md`, and full PCB schematics and 3D renders.
- **Open Source Preparation**: Added `LICENSE`, GitHub issue templates, and `.gitattributes` for LF line endings.

### Changed
- Refactored ATmega8A UART command processor to the structured `FV5.1.0` protocol (`SET:` and `GET:`).
- Fixed Android Gradle `gradle.properties` configuration allowing cross-drive releases.
- Consolidated repository into a monorepo setup encompassing Firmware, Mobile App, and Schematics.