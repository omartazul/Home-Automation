// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

/// Immutable snapshot of every controllable device's state, displayed on the
/// [LcdDisplay] panel.
class LcdData {
  /// Whether the ESP-01S WiFi bridge is reachable.
  final bool isConnected;

  /// Whether the ceiling fan is running.
  final bool fanOn;

  /// Fan speed level in the range 0–9 (0 = off / idle).
  final int fanSpeed;

  /// Whether light 1 is on.
  final bool light1On;

  /// Whether light 2 is on.
  final bool light2On;

  /// Whether the main power relay is on.
  final bool powerOn;

  /// Whether the smart plug is on.
  final bool plugOn;

  /// Configured device name shown on the LCD title area.
  final String deviceName;

  const LcdData({
    this.isConnected = false,
    this.fanOn = false,
    this.fanSpeed = 0,
    this.light1On = false,
    this.light2On = false,
    this.powerOn = false,
    this.plugOn = false,
    this.deviceName = 'Home Control',
  });

  /// Maximum speed level (ATmega8A firmware supports 9 levels).
  static const int maxSpeed = 9;

  LcdDataBuilder toBuilder() => LcdDataBuilder(this);
}

/// A builder for [LcdData] to eliminate code duplication and avoid methods with many arguments.
class LcdDataBuilder {
  bool _isConnected;
  bool _fanOn;
  int _fanSpeed;
  bool _light1On;
  bool _light2On;
  bool _powerOn;
  bool _plugOn;
  String _deviceName;

  LcdDataBuilder(LcdData data)
      : _isConnected = data.isConnected,
        _fanOn = data.fanOn,
        _fanSpeed = data.fanSpeed,
        _light1On = data.light1On,
        _light2On = data.light2On,
        _powerOn = data.powerOn,
        _plugOn = data.plugOn,
        _deviceName = data.deviceName;

  void setConnection(bool connected) => _isConnected = connected;
  void setFan(bool fan) => _fanOn = fan;
  void setFanSpeed(int speed) => _fanSpeed = speed;
  void setLight1(bool light1) => _light1On = light1;
  void setLight2(bool light2) => _light2On = light2;
  void setPower(bool power) => _powerOn = power;
  void setPlug(bool plug) => _plugOn = plug;
  void setDeviceName(String name) => _deviceName = name;

  LcdData build() {
    return LcdData(
      isConnected: _isConnected,
      fanOn: _fanOn,
      fanSpeed: _fanSpeed,
      light1On: _light1On,
      light2On: _light2On,
      powerOn: _powerOn,
      plugOn: _plugOn,
      deviceName: _deviceName,
    );
  }
}

/// Represents a network host address (IP or mDNS hostname) for the device.
class DeviceAddress {
  final String host;
  const DeviceAddress(this.host);

  /// Returns the base URL for this device address.
  String get baseUrl => 'http://$host';
  
  /// Returns the WebSocket URL for this device address.
  String get wsUrl => 'ws://$host:81';

  @override
  String toString() => host;
}

/// Represents Wi-Fi credentials for connecting the ESP-01S to a network.
class WifiCredentials {
  final String ssid;
  final String password;
  const WifiCredentials(this.ssid, this.password);
}
