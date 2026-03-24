// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

/// Domain exception for API failures with user-safe messaging.
class EspApiException implements Exception {
  final String message;
  final Object? cause;

  const EspApiException(this.message, {this.cause});

  @override
  String toString() => message;
}

/// REST client for the ESP-01S bridge firmware.
///
/// All calls target `http://<ip>` where `<ip>` is the saved device address.
/// The device IP is persisted via [SharedPreferences].
///
/// ## Structured Command Protocol (FV5.1.0)
///
/// Commands sent to the ATmega8A:
/// ```
/// SET:PWR:ON    SET:PWR:OFF
/// SET:FAN:ON    SET:FAN:OFF    SET:FAN:SPD:5
/// SET:LT1:ON    SET:LT1:OFF
/// SET:LT2:ON    SET:LT2:OFF
/// SET:PLG:ON    SET:PLG:OFF
/// SET:MINP:50
/// GET:STATUS    GET:MINP
/// ```
///
/// Responses: `OK:PWR:ON`, `ERR:PWR_OFF`, `STATUS:PWR=ON,FAN=ON,...`
class EspApi {
  EspApi._();
  static final EspApi instance = EspApi._();
  final http.Client _client = http.Client();

  static const String _prefKeyIp = 'esp_device_ip';
  static const DeviceAddress defaultApAddress = DeviceAddress('192.168.4.1');
  static const DeviceAddress universalHost = DeviceAddress('homeauto.local');
  static const Duration _timeout = Duration(seconds: 5);

  DeviceAddress? _deviceAddress;
  WebSocketChannel? _wsChannel;
  final _statusController = StreamController<LcdData>.broadcast();

  /// Stream of real-time device status pushed from the ESP over WebSockets.
  Stream<LcdData> get statusStream => _statusController.stream;

  /// Current device IP or mDNS hostname.
  DeviceAddress get deviceAddress => _deviceAddress ?? universalHost;

  /// Always true now as we fall back to mDNS.
  bool get hasDevice => true;

  // Persistence helpers.

  Future<void> loadSavedIp() async {
    final prefs = await SharedPreferences.getInstance();
    final ip = prefs.getString(_prefKeyIp);
    if (ip != null) {
      _deviceAddress = DeviceAddress(ip);
    }
  }

  /// Connects to the ESP WebSocket to listen for instant hardware status updates.
  void connectWebSocket() {
    _wsChannel?.sink.close();
    final wsUri = Uri.parse(deviceAddress.wsUrl);
    try {
      _wsChannel = WebSocketChannel.connect(wsUri);
      _wsChannel!.stream.listen(
        (message) {
          try {
            final res = jsonDecode(message);
            if (res is Map<String, dynamic> && res['ok'] == true) {
              _statusController.add(_parseStatusMap(res));
            }
          } catch (_) {}
        },
        onDone: () => Future.delayed(const Duration(seconds: 3), connectWebSocket),
        onError: (_) => Future.delayed(const Duration(seconds: 3), connectWebSocket),
      );
    } catch (_) {}
  }

  Future<void> setDeviceIp(String ip) async {
    _deviceAddress = DeviceAddress(ip);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKeyIp, ip);
  }

  Future<void> clearDeviceIp() async {
    _deviceAddress = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKeyIp);
  }

  // Internal request helpers.

  Map<String, String> get _authHeaders {
    final credentials = 'home:123456789';
    final encoded = base64Encode(utf8.encode(credentials));
    return {'Authorization': 'Basic $encoded'};
  }

  Uri _uri(String path, [DeviceAddress? overrideAddress]) =>
      Uri.parse('${overrideAddress?.baseUrl ?? deviceAddress.baseUrl}$path');

  Map<String, dynamic> _decodeJsonMap(http.Response res, Uri uri) {
    try {
      final decoded = jsonDecode(res.body);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      throw const FormatException('Expected JSON object');
    } on FormatException catch (e) {
      throw EspApiException('Invalid response received from device.', cause: e);
    }
  }

  Never _throwNetworkError(Object error) {
    if (error is SocketException) {
      throw const EspApiException('Network error: Device unreachable.');
    }
    if (error is TimeoutException) {
      throw const EspApiException(
        'Connection timed out. Device may be offline.',
      );
    }
    throw EspApiException('Unexpected network error.', cause: error);
  }

  void _ensureHttpOk(http.Response res, Uri uri) {
    if (res.statusCode != 200) {
      throw EspApiException(
        'Device request failed (HTTP ${res.statusCode}) at ${uri.path}.',
      );
    }
  }

  Future<Map<String, dynamic>> _get(String path, [DeviceAddress? address]) async {
    final uri = _uri(path, address);
    try {
      final res = await _client.get(uri, headers: _authHeaders).timeout(_timeout);
      _ensureHttpOk(res, uri);
      return _decodeJsonMap(res, uri);
    } on EspApiException {
      rethrow;
    } catch (e) {
      _throwNetworkError(e);
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, [
    DeviceAddress? address,
  ]) async {
    final uri = _uri(path, address);
    try {
      final res = await _client
          .post(
            uri,
            headers: {'Content-Type': 'application/json', ..._authHeaders},
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      _ensureHttpOk(res, uri);
      return _decodeJsonMap(res, uri);
    } on EspApiException {
      rethrow;
    } catch (e) {
      _throwNetworkError(e);
    }
  }

  // Public API.

  /// Scan for WiFi networks (used during provisioning via AP IP).
  Future<List<Map<String, dynamic>>> scanWifi([DeviceAddress? address]) async {
    final uri = _uri('/api/wifi/scan', address);
    try {
      final res = await _client.get(uri).timeout(const Duration(seconds: 10));
      _ensureHttpOk(res, uri);
      final decoded = jsonDecode(res.body);
      if (decoded is! List) {
        throw const FormatException('Expected JSON array');
      }
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    } on EspApiException {
      rethrow;
    } on FormatException catch (e) {
      throw EspApiException(
        'Invalid Wi-Fi scan response from device.',
        cause: e,
      );
    } catch (e) {
      _throwNetworkError(e);
    }
  }

  /// Configure Wi-Fi on the ESP (used during AP provisioning).
  Future<Map<String, dynamic>> configureWifi(
    WifiCredentials credentials, [
    DeviceAddress? address,
  ]) => _postJson('/api/wifi', {'ssid': credentials.ssid, 'pass': credentials.password}, address);

  /// Get device info.
  Future<Map<String, dynamic>> getInfo([DeviceAddress? address]) => _get('/api/info', address);

  /// Send a structured command to ATmega8A (e.g. "SET:PWR:ON").
  Future<String> sendCommand(String cmd) async {
    if (cmd.trim().isEmpty) {
      throw const EspApiException('Command cannot be empty.');
    }
    final res = await _postJson('/api/command', {'cmd': cmd});
    final response = (res['response'] as String?)?.trim() ?? '';
    if (response.startsWith('ERR:')) {
      throw EspApiException('Device rejected command: $response');
    }
    return response;
  }

  /// Request ATmega8A status and return parsed [LcdData].
  ///
  /// The ESP bridge parses the structured `STATUS:` response into JSON with
  /// keys: `pwr`, `fan`, `spd`, `lt1`, `lt2`, `plg`, `minp`, `fw`.
  Future<LcdData> getStatus() async {
    final res = await _get('/api/status');
    return _parseStatusMap(res);
  }

  LcdData _parseStatusMap(Map<String, dynamic> res) {
    bool parseOn(dynamic value) {
      if (value is bool) return value;
      return value?.toString().toUpperCase() == 'ON';
    }

    final pwr = parseOn(res['pwr']);
    final fan = parseOn(res['fan']);
    final spd = int.tryParse(res['spd']?.toString() ?? '0') ?? 0;
    final lt1 = parseOn(res['lt1']);
    final lt2 = parseOn(res['lt2']);
    final plg = parseOn(res['plg']);
    final name = (res['name'] as String?)?.trim();
    return LcdData(
      isConnected: true,
      powerOn: pwr,
      fanOn: fan,
      fanSpeed: spd,
      light1On: lt1,
      light2On: lt2,
      plugOn: plg,
      deviceName: (name == null || name.isEmpty) ? 'Home Control' : name,
    );
  }

  /// Get the configured device name from the ESP bridge.
  Future<String> getDeviceName([DeviceAddress? address]) async {
    final res = await _get('/api/device-name', address);
    final name = (res['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      throw const EspApiException('Device name is empty.');
    }
    return name;
  }

  /// Set a new device name; device reboots to apply Wi-Fi identity changes.
  Future<String> setDeviceName(String name, [DeviceAddress? address]) async {
    final trimmed = name.trim();
    if (trimmed.length < 3 || trimmed.length > 24) {
      throw const EspApiException('Name must be 3-24 characters long.');
    }
    final res = await _postJson('/api/device-name', {'name': trimmed}, address);
    final applied = (res['name'] as String?)?.trim() ?? '';
    if (applied.isEmpty) {
      throw const EspApiException('Device did not return an applied name.');
    }
    return applied;
  }

  /// Send a raw command and return the raw response string (for terminal).
  Future<String> sendRaw(String cmd) async {
    if (cmd.trim().isEmpty) {
      throw const EspApiException('Command cannot be empty.');
    }
    final res = await _postJson('/api/command', {'cmd': cmd});
    return (res['response'] as String?)?.trim() ?? '';
  }

  /// Reset the ATmega8A.
  Future<void> resetMCU() async {
    await _postJson('/api/reset-mcu', {});
  }

  /// Factory-reset the ESP (clears WiFi, reboots into AP mode).
  Future<void> factoryReset() async {
    await _postJson('/api/factory-reset', {});
  }

  /// Flash the device with a firmware binary (.bin, .hex, or .home).
  Future<void> flashUpdate(List<int> bytes, String filename) async {
    final uri = _uri('/api/update');
    try {
      final req = http.MultipartRequest('POST', uri);
      req.headers.addAll(_authHeaders);
      req.files.add(
        http.MultipartFile.fromBytes('update', bytes, filename: filename),
      );
      final streamedResponse = await req.send().timeout(
        const Duration(minutes: 5),
      );
      final res = await http.Response.fromStream(streamedResponse);
      final errorPattern = RegExp(r'FAIL|Error|error');
      if (res.statusCode != 200 || errorPattern.hasMatch(res.body)) {
        throw EspApiException(
          'Update failed (HTTP ${res.statusCode}): ${res.body}',
        );
      }
    } on EspApiException {
      rethrow;
    } catch (e) {
      _throwNetworkError(e);
    }
  }

  /// Quick connectivity check.
  Future<bool> ping([DeviceAddress? address]) async {
    try {
      await getInfo(address);
      return true;
    } catch (_) {
      return false;
    }
  }
}
