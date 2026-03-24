// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../api.dart';
import 'wifi_setup_screen.dart';

/// Settings screen accessed from the main home screen gear icon.
///
/// Provides:
///  - Device IP configuration / WiFi provisioning
///  - Serial terminal (send arbitrary commands) - Hidden by default
///  - OTA firmware update (Intel HEX / .home)
///  - Reboot Device (Reset ATmega8A)
///  - Reset to Factory Default (ESP-01S)
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _api = EspApi.instance;
  static const int _maxTerminalLines = 300;
  // Allow letters, numbers, spaces, and common punctuation (3-24 chars)
  static final RegExp _namePattern = RegExp(
    r"^[A-Za-z0-9 _.,!@#%&()\-+=']{3,24}$",
  );

  // Serial terminal state.
  final _cmdController = TextEditingController();
  final _scrollController = ScrollController();
  final List<_TerminalLine> _terminalLines = [];

  // View state.
  bool _busy = false;
  bool _isConnected = false;
  String? _espInfo;
  String _deviceName = 'Home Control';

  int _debugTapCount = 0;
  bool _isDebugMode = false;

  @override
  void initState() {
    super.initState();
    _refreshInfo();
  }

  @override
  void dispose() {
    _cmdController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // Actions.

  void _appendTerminalLine(_TerminalLine line) {
    _terminalLines.add(line);
    if (_terminalLines.length > _maxTerminalLines) {
      _terminalLines.removeRange(0, _terminalLines.length - _maxTerminalLines);
    }
  }

  Future<void> _refreshInfo() async {
    if (!_api.hasDevice) return;
    setState(() => _busy = true);
    try {
      final info = await _api.getInfo();
      if (!mounted) return;
      setState(() {
        _isConnected = true;
        final reportedName = (info['name'] as String?)?.trim();
        _deviceName = (reportedName == null || reportedName.isEmpty)
            ? _deviceName
            : reportedName;
        final mdns = info['mdns']?.toString() ?? 'n/a';
        _espInfo =
            'Name: $_deviceName  mDNS: $mdns\n'
            'Mode: ${info['mode']}  IP: ${info['ip']}\n'
            'SSID: ${info['ssid']}  RSSI: ${info['rssi']}\n'
            'Heap: ${info['heap']}  Uptime: ${info['uptime']}s';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _espInfo = null;
        });
      }
      _showError('Cannot reach device: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _renameDevice() async {
    if (!_api.hasDevice) return;
    String newName = _deviceName;
    String? validationError;

    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Rename Device'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: newName,
                  autofocus: true,
                  maxLength: 24,
                  onChanged: (v) => newName = v,
                  decoration: InputDecoration(
                    labelText: 'Device name',
                    hintText: 'HomeAuto_LivingRoom',
                    errorText: validationError,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Allowed: letters, numbers, spaces, and punctuation (3-24 chars).',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final candidate = newName.trim();
                  if (!_namePattern.hasMatch(candidate)) {
                    setDialogState(() {
                      validationError = 'Invalid name format';
                    });
                    return;
                  }
                  newName = candidate;
                  Navigator.pop(ctx, true);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );

    if (approved != true) {
      return;
    }

    setState(() => _busy = true);
    try {
      final applied = await _api.setDeviceName(newName);
      if (!mounted) return;
      setState(() => _deviceName = applied);
      _showSuccess(
        'Device renamed to "$applied". Reconnecting after reboot...',
      );

      bool reconnected = false;
      for (int i = 0; i < 8; i++) {
        await Future.delayed(const Duration(seconds: 3));
        if (!mounted) return;
        if (await _api.ping()) {
          reconnected = true;
          break;
        }
      }

      if (reconnected) {
        await _refreshInfo();
      } else {
        if (mounted) {
          setState(() {
            _isConnected = false;
            _espInfo = null;
          });
        }
        _showError('Reconnection timed out. Please refresh manually.');
      }
    } catch (e) {
      _showError('Rename failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendCommand() async {
    final cmd = _cmdController.text.trim();
    if (cmd.isEmpty || !_api.hasDevice) return;

    setState(() {
      _appendTerminalLine(_TerminalLine('> $cmd', isCommand: true));
      _busy = true;
    });
    _cmdController.clear();

    try {
      final response = await _api.sendRaw(cmd);
      if (!mounted) return;
      setState(() => _appendTerminalLine(_TerminalLine(response)));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _appendTerminalLine(_TerminalLine('ERROR: $e', isError: true)),
      );
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _getStatus() async {
    if (!_api.hasDevice) return;
    setState(() => _busy = true);
    try {
      final status = await _api.sendRaw('GET:STATUS');
      if (!mounted) return;
      setState(() {
        _appendTerminalLine(_TerminalLine('> GET:STATUS', isCommand: true));
        _appendTerminalLine(_TerminalLine(status));
      });
    } catch (e) {
      _showError('Status request failed: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scrollToBottom();
      }
    }
  }

  Future<void> _resetMCU() async {
    if (!_api.hasDevice) return;
    final confirm = await _confirmAction('Reboot Device?');
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      await _api.resetMCU();
      _showSuccess('Device has been rebooted');
    } catch (e) {
      _showError('Reboot failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _factoryReset() async {
    if (!_api.hasDevice) return;
    final confirm = await _confirmAction(
      'Reset to Factory Default?\n\n'
      'This erases stored Wi-Fi credentials and reboots the device into AP mode. '
      'You will need to re-provision it.',
    );
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      await _api.factoryReset();
      await _api.clearDeviceIp();
      if (!mounted) return;
      setState(() {
        _espInfo = null;
      });
      _showSuccess('Factory reset complete. Device is now in AP mode.');
    } catch (e) {
      _showError('Factory reset failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _installUnifiedUpdate() async {
    if (!_api.hasDevice) return;

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['home', 'bin', 'hex'],
        withData: true,
      );
    } catch (e) {
      _showError('Failed to open file picker: $e');
      return;
    }

    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;

    List<int> bytes;
    if (file.bytes != null) {
      bytes = file.bytes!.toList();
    } else if (file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (e) {
        _showError('Cannot read selected file: $e');
        return;
      }
    } else {
      _showError('Cannot read file');
      return;
    }

    if (!mounted) return;

    final confirm = await _confirmAction('Install ${file.name} to the device?');
    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      await _api.flashUpdate(bytes, file.name);
      _showSuccess('Update complete');
    } catch (e) {
      _showError('Update failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWifiSetup() async {
    final result = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const WifiSetupScreen()));
    if (result != null && result.isNotEmpty) {
      await _api.setDeviceIp(result);
      if (!mounted) return;

      setState(() => _busy = true);
      bool reconnected = false;
      for (int i = 0; i < 8; i++) {
        await Future.delayed(const Duration(seconds: 3));
        if (!mounted) return;
        if (await _api.ping()) {
          reconnected = true;
          break;
        }
      }

      if (reconnected) {
        await _refreshInfo();
      } else {
        if (mounted) {
          setState(() {
            _isConnected = false;
            _espInfo = null;
          });
        }
        _showError('Device not found. Connect to same Wi-Fi and refresh.');
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  // Helpers.

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.red,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: AppColors.primaryMaroon,
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  Future<bool?> _confirmAction(String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text('Proceed'),
          ),
        ],
      ),
    );
  }

  // Build.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: AppColors.primaryMaroon,
        foregroundColor: AppColors.white,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: AppColors.primaryMaroon,
          statusBarIconBrightness: Brightness.light,
        ),
      ),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: [
              _buildSection('Device Connection', [
                  if (_isConnected)
                    _tile(
                      icon: Icons.badge_rounded,
                      title: 'Device Name',
                      subtitle: _deviceName,
                      onTap: _renameDevice,
                    ),
                  _tile(
                    icon: Icons.wifi_rounded,
                    title: 'WiFi Provisioning',
                    subtitle: 'Connect ESP to your router',
                    onTap: _openWifiSetup,
                  ),
                  if (_espInfo != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Text(
                        _espInfo!,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: AppColors.iconDark,
                        ),
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    child: OutlinedButton.icon(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        _refreshInfo();
                      },
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('Refresh Info'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primaryMaroon,
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                if (_isDebugMode) ...[
                  _buildSection('Serial Terminal', [_buildTerminal()]),
                  const SizedBox(height: 8),
                ],

                _buildSection('Firmware', [
                  _tile(
                    icon: Icons.info_outline_rounded,
                    title: 'Firmware Version',
                    subtitle: 'FV5.1.0',
                    onTap: () {
                      HapticFeedback.lightImpact();
                      if (_isDebugMode) return;
                      _debugTapCount++;
                      if (_debugTapCount >= 10) {
                        setState(() => _isDebugMode = true);
                        _showSuccess('Debug mode enabled');
                      }
                    },
                  ),
                  _tile(
                    icon: Icons.system_update_alt_rounded,
                    title: 'Update Firmware',
                    onTap: _api.hasDevice ? _installUnifiedUpdate : null,
                  ),
                ]),
                const SizedBox(height: 8),
                _buildSection('Device Control', [
                  _tile(
                    icon: Icons.restart_alt_rounded,
                    title: 'Reboot Device',
                    onTap: _api.hasDevice ? _resetMCU : null,
                  ),
                  _tile(
                    icon: Icons.delete_forever_rounded,
                    title: 'Reset to Factory Default',
                    onTap: _api.hasDevice ? _factoryReset : null,
                    destructive: true,
                  ),
                ]),
                const SizedBox(height: 24),
              ],
            ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black26,
                child: Center(
                  child: CircularProgressIndicator(color: AppColors.primaryMaroon),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSection(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: AppColors.primaryMaroon,
            ),
          ),
        ),
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(children: children),
        ),
      ],
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    VoidCallback? onTap,
    bool destructive = false,
  }) {
    final color = destructive ? AppColors.red : AppColors.primaryMaroon;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(
        title,
        style: TextStyle(
          color: destructive ? AppColors.red : AppColors.iconDark,
        ),
      ),
      subtitle: subtitle != null
          ? Text(subtitle, style: const TextStyle(fontSize: 12))
          : null,
      trailing: onTap != null
          ? const Icon(Icons.chevron_right, color: AppColors.iconDark)
          : null,
      onTap: onTap != null
          ? () {
              HapticFeedback.lightImpact();
              onTap();
            }
          : null,
    );
  }

  Widget _buildTerminal() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // Terminal output area.
          Container(
            height: 180,
            width: double.infinity,
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(8),
              itemCount: _terminalLines.length,
              itemBuilder: (_, i) {
                final line = _terminalLines[i];
                return Text(
                  line.text,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    color: line.isError
                        ? Colors.redAccent
                        : line.isCommand
                        ? Colors.cyanAccent
                        : Colors.greenAccent,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          // Command input and actions.
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cmdController,
                  decoration: InputDecoration(
                    hintText: 'Command (a, b, s, MINP?...)',
                    hintStyle: TextStyle(
                      color: AppColors.iconDark.withAlpha(120),
                    ),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
                  onSubmitted: (_) => _sendCommand(),
                ),
              ),
              const SizedBox(width: 8),
              _actionButton(
                Icons.send_rounded,
                _api.hasDevice ? _sendCommand : null,
              ),
              const SizedBox(width: 4),
              _actionButton(
                Icons.info_outline_rounded,
                _api.hasDevice ? _getStatus : null,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton(IconData icon, VoidCallback? onTap) {
    return SizedBox(
      width: 40,
      height: 40,
      child: IconButton(
        onPressed: onTap != null
            ? () {
                HapticFeedback.lightImpact();
                onTap();
              }
            : null,
        icon: Icon(icon, size: 20),
        style: IconButton.styleFrom(
          backgroundColor: AppColors.primaryMaroon,
          foregroundColor: AppColors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

class _TerminalLine {
  final String text;
  final bool isCommand;
  final bool isError;

  const _TerminalLine(
    this.text, {
    this.isCommand = false,
    this.isError = false,
  });
}
