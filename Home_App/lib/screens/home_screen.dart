// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models.dart';
import '../api.dart';
import '../widgets/home_widgets.dart';
import '../widgets/lcd_display.dart';
import 'settings_screen.dart';

/// Main home screen of the application.
///
/// Owns all device state and drives the [LcdDisplay] panel.
/// Communicates with the ATmega8A through the ESP-01S REST bridge.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _api = EspApi.instance;
  StreamSubscription<LcdData>? _wsSubscription;

  // Device state.
  LcdData _lcd = const LcdData();

  void _updateLcd(LcdData Function(LcdData) updater) {
    if (mounted) {
      setState(() => _lcd = updater(_lcd));
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.red,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  /// Pull the real device state and update the LCD.
  ///
  /// This is the authoritative sync; the ATmega EEPROM state is the source of truth.
  Future<void> _syncState() async {
    if (!_api.hasDevice) return;
    try {
      final actual = await _api.getStatus();
      if (mounted) setState(() => _lcd = actual);
    } catch (e) {
      if (mounted) _updateLcd((d) => (d.toBuilder()..setConnection(false)).build());
      debugPrint('State sync failed: $e');
    }
  }

  /// Sends a structured command, applies optimistic UI feedback, and then
  /// synchronizes from the device when needed.
  Future<void> _send(String cmd, LcdData Function(LcdData) optimistic) async {
    _updateLcd(optimistic); // Apply immediate visual feedback.
    if (!_api.hasDevice) return;
    try {
      await _api.sendCommand(cmd);
      _updateLcd((d) => (d.toBuilder()..setConnection(true)).build());
    } catch (e) {
      _updateLcd((d) => (d.toBuilder()..setConnection(false)).build());
      await _syncState();
      _showError('Command failed: $e');
    }
  }

  void _onPower() {
    final target = !_lcd.powerOn;
    _send(
      'SET:PWR:${target ? "ON" : "OFF"}',
      (d) => (d.toBuilder()..setPower(target)).build(),
    );
  }

  void _onPlug() {
    final target = !_lcd.plugOn;
    _send(
      'SET:PLG:${target ? "ON" : "OFF"}',
      (d) => (d.toBuilder()..setPlug(target)).build(),
    );
  }

  void _onFan() {
    final target = !_lcd.fanOn;
    // Do not guess the speed; the ATmega restores its EEPROM-backed value.
    _send('SET:FAN:${target ? "ON" : "OFF"}', (d) => (d.toBuilder()..setFan(target)).build());
  }

  void _onMinus() {
    final spd = (_lcd.fanSpeed - 1).clamp(1, LcdData.maxSpeed);
    _send('SET:FAN:SPD:$spd', (d) => (d.toBuilder()..setFanSpeed(spd)).build());
  }

  void _onPlus() {
    final spd = (_lcd.fanSpeed + 1).clamp(1, LcdData.maxSpeed);
    _send('SET:FAN:SPD:$spd', (d) => (d.toBuilder()..setFanSpeed(spd)).build());
  }

  void _onLight1() {
    final target = !_lcd.light1On;
    _send(
      'SET:LT1:${target ? "ON" : "OFF"}',
      (d) => (d.toBuilder()..setLight1(target)).build(),
    );
  }

  void _onLight2() {
    final target = !_lcd.light2On;
    _send(
      'SET:LT2:${target ? "ON" : "OFF"}',
      (d) => (d.toBuilder()..setLight2(target)).build(),
    );
  }

  Future<void> _onWifiTap() async {
    if (!_lcd.isConnected) {
      await _syncState();
    }
  }

  void _openSettings() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SettingsScreen())).then((_) {
      // Refresh connection state when returning from settings.
      if (mounted) {
        _checkConnection();
      }
    });
  }

  // Lifecycle.
  @override
  void initState() {
    super.initState();
    _initApi();
  }

  @override
  void dispose() {
    _wsSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initApi() async {
    await _api.loadSavedIp();
    
    // Connect WebSocket for instant push updates
    _api.connectWebSocket();
    _wsSubscription = _api.statusStream.listen((data) {
      if (mounted) {
        setState(() => _lcd = data);
      }
    });

    _checkConnection();
  }

  Future<void> _checkConnection() => _syncState();

  // Build.
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: AppColors.primaryMaroon,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              // LCD display row.
              Expanded(flex: 22, child: LcdDisplay(data: _lcd)),

              // Wi-Fi and settings controls.
              Expanded(
                flex: 11,
                child: ControlRow(
                  semanticLabel: 'wifi_and_settings_container',
                  children: [
                    MomentaryButton(
                      name: 'wifi_button',
                      iconData: Icons.wifi_rounded,

                      iconScale: 0.75,
                      pressedIconScale: 0.70,
                      onTap: _onWifiTap,
                    ),
                    MomentaryButton(
                      name: 'settings_button',
                      iconData: Icons.settings_rounded,
                      iconScale: 0.70,
                      pressedIconScale: 0.66,
                      onTap: _openSettings,
                    ),
                  ],
                ),
              ),

              // Power and plug controls.
              Expanded(
                flex: 17,
                child: ControlRow(
                  semanticLabel: 'power_and_plug_container',
                  children: [
                    MomentaryButton(
                      name: 'power_button',
                      asset: AppAssets.powerButtonNormal,
                      assetPressed: AppAssets.powerButtonPressed,
                      iconData: Icons.power_settings_new_rounded,
                      normalIconColor: AppColors.red,
                      iconScale: 0.75,
                      pressedIconScale: 0.71,
                      onTap: _onPower,
                    ),
                    MomentaryButton(
                      name: 'plug_button',
                      iconData: Icons.electrical_services_rounded,
                      iconScale: 0.75,
                      pressedIconScale: 0.71,
                      onTap: _onPlug,
                    ),
                  ],
                ),
              ),

              // Fan controls.
              Expanded(
                flex: 17,
                child: ControlRow(
                  semanticLabel: 'fan_container',
                  alignment: MainAxisAlignment.center,
                  children: [
                    MomentaryButton(
                      name: 'fan_button',
                      svgIconAsset: AppAssets.fanIcon,
                      iconScale: 0.77,
                      pressedIconScale: 0.73,
                      onTap: _onFan,
                    ),
                  ],
                ),
              ),

              // Fan speed decrement and increment controls.
              Expanded(
                flex: 11,
                child: ControlRow(
                  semanticLabel: 'minus_and_plus_container',
                  children: [
                    MomentaryButton(
                      name: 'minus_button',
                      iconData: Icons.remove_circle_rounded,
                      iconScale: 0.70,
                      pressedIconScale: 0.66,
                      onTap: _onMinus,
                    ),
                    MomentaryButton(
                      name: 'plus_button',
                      iconData: Icons.add_circle_rounded,
                      iconScale: 0.70,
                      pressedIconScale: 0.66,
                      onTap: _onPlus,
                    ),
                  ],
                ),
              ),

              // Light controls.
              Expanded(
                flex: 17,
                child: ControlRow(
                  semanticLabel: 'light1_and_light2_container',
                  children: [
                    MomentaryButton(
                      name: 'light1_button',
                      iconData: Icons.emoji_objects_outlined,
                      iconScale: 0.80,
                      pressedIconScale: 0.76,
                      onTap: _onLight1,
                    ),
                    MomentaryButton(
                      name: 'light2_button',
                      iconData: Icons.emoji_objects_outlined,
                      iconScale: 0.80,
                      pressedIconScale: 0.76,
                      onTap: _onLight2,
                    ),
                  ],
                ),
              ),

              // Signature footer.
              const Expanded(
                flex: 5,
                child: SignatureFooter(text: 'Tazul Islam'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
