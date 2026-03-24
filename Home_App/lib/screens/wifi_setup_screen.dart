// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants.dart';
import '../models.dart';
import '../api.dart';

/// Wi-Fi provisioning screen.
///
/// Guides the user to:
///  1. Connect their phone to the ESP-01S access point (HomeAuto_XXXX)
///  2. Scan available networks
///  3. Select one and provide the password
///  4. The ESP saves credentials and reboots in STA mode
///  5. User re-joins their home network and enters the new device IP
///
/// Returns the new device IP [String] via [Navigator.pop] on success.
class WifiSetupScreen extends StatefulWidget {
  const WifiSetupScreen({super.key});

  @override
  State<WifiSetupScreen> createState() => _WifiSetupScreenState();
}

class _WifiSetupScreenState extends State<WifiSetupScreen> {
  final _api = EspApi.instance;
  final _passController = TextEditingController();

  int _step =
      0; // 0: intro, 1: scanning, 2: pick network, 3: enter pass, 4: done
  List<Map<String, dynamic>> _networks = [];
  String? _selectedSsid;
  bool _busy = false;
  String? _errorMsg;

  @override
  void dispose() {
    _passController.dispose();
    super.dispose();
  }

  // Actions.

  int _safeRssi(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '') ?? -100;
  }

  bool _safeOpen(dynamic value) {
    if (value is bool) return value;
    return value?.toString().toLowerCase() == 'true';
  }

  Future<void> _scanNetworks() async {
    setState(() {
      _busy = true;
      _step = 1;
      _errorMsg = null;
    });
    try {
      final raw = await _api.scanWifi(EspApi.defaultApAddress);
      _networks = raw
          .where((n) => (n['ssid']?.toString().trim().isNotEmpty ?? false))
          .toList(growable: false);
      // Sort by strongest signal first.
      _networks.sort(
        (a, b) => _safeRssi(b['rssi']).compareTo(_safeRssi(a['rssi'])),
      );
      if (!mounted) return;
      setState(() => _step = 2);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMsg =
            'Cannot reach ESP AP at ${EspApi.defaultApAddress.host}.\n\n'
            'Make sure your phone is connected to the "HomeAuto_XXXX" WiFi network.\n\n'
            'Error: $e';
        _step = 0;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _pickNetwork(String ssid) {
    _selectedSsid = ssid;
    _passController.clear();
    setState(() => _step = 3);
  }

  Future<void> _submitCredentials() async {
    if (_selectedSsid == null) return;
    setState(() {
      _busy = true;
      _errorMsg = null;
    });
    try {
      final credentials = WifiCredentials(_selectedSsid!, _passController.text);
      await _api.configureWifi(
        credentials,
        EspApi.defaultApAddress,
      );
      if (!mounted) return;
      setState(() => _step = 4);
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMsg = 'Failed to save credentials: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish() {
    Navigator.of(context).pop('homeauto.local');
  }

  // Build.

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('WiFi Setup'),
        backgroundColor: AppColors.primaryMaroon,
        foregroundColor: AppColors.white,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarColor: AppColors.primaryMaroon,
          statusBarIconBrightness: Brightness.light,
        ),
      ),
      body: _busy
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primaryMaroon),
            )
          : Padding(padding: const EdgeInsets.all(20), child: _buildStep()),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 0:
        return _buildIntro();
      case 2:
        return _buildNetworkList();
      case 3:
        return _buildPasswordEntry();
      case 4:
        return _buildComplete();
      default:
        return const SizedBox.shrink();
    }
  }

  // Step 0: connection instructions.
  Widget _buildIntro() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          Icons.wifi_tethering_rounded,
          size: 48,
          color: AppColors.primaryMaroon,
        ),
        const SizedBox(height: 16),
        const Text(
          'Connect to the ESP Access Point',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          '1. Open your phone\'s Wi-Fi settings\n'
          '2. Connect to the network named "HomeAuto_XXXX"\n'
          '   (no password required)\n'
          '3. Come back here and tap "Scan Networks"',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        if (_errorMsg != null) ...[
          const SizedBox(height: 16),
          Text(
            _errorMsg!,
            style: const TextStyle(color: Colors.red, fontSize: 13),
          ),
        ],
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _scanNetworks,
            icon: const Icon(Icons.search_rounded),
            label: const Text('Scan Networks'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryMaroon,
              foregroundColor: AppColors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // Step 2: network list.
  Widget _buildNetworkList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Available Networks',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              onPressed: _scanNetworks,
              icon: const Icon(
                Icons.refresh_rounded,
                color: AppColors.primaryMaroon,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _networks.isEmpty
              ? const Center(child: Text('No networks found'))
              : ListView.separated(
                  itemCount: _networks.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final net = _networks[i];
                    final ssid = net['ssid'].toString();
                    final rssi = _safeRssi(net['rssi']);
                    final open = _safeOpen(net['open']);
                    return ListTile(
                      leading: Icon(
                        rssi > -50
                            ? Icons.wifi_rounded
                            : rssi > -70
                            ? Icons.wifi_2_bar_rounded
                            : Icons.wifi_1_bar_rounded,
                        color: AppColors.primaryMaroon,
                      ),
                      title: Text(ssid),
                      subtitle: Text('$rssi dBm${open ? " · Open" : ""}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _pickNetwork(ssid),
                    );
                  },
                ),
        ),
      ],
    );
  }

  // Step 3: password entry.
  Widget _buildPasswordEntry() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Connect to "$_selectedSsid"',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _passController,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'Wi-Fi Password',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        if (_errorMsg != null) ...[
          const SizedBox(height: 12),
          Text(
            _errorMsg!,
            style: const TextStyle(color: Colors.red, fontSize: 13),
          ),
        ],
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submitCredentials,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryMaroon,
              foregroundColor: AppColors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Connect'),
          ),
        ),
      ],
    );
  }

  // Step 4: completion summary.
  Widget _buildComplete() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.check_circle_rounded, size: 48, color: Colors.green),
        const SizedBox(height: 16),
        const Text(
          'Credentials Saved!',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'The ESP is now rebooting and connecting to your router.\n\n'
          '1. Reconnect your phone to your home Wi-Fi\n'
          '2. The app will automatically find the device via "homeauto.local".',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _finish,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primaryMaroon,
              foregroundColor: AppColors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: const Text('Finish Setup'),
          ),
        ),
      ],
    );
  }
}
