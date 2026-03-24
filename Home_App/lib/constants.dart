// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'package:flutter/material.dart';

/// Centralized color palette for the application.
///
/// All colors are defined here to ensure consistency and make
/// theme changes easy in one place.
class AppColors {
  AppColors._();

  static const Color primaryMaroon = Color(0xFF5B1029);
  static const Color scaffoldBackground = Color(0xFFC0BFBF);
  static const Color iconDark = Color(0xFF333333);
  static const Color white = Colors.white;
  static const Color red = Colors.red;
}

/// Centralized asset path constants for the application.
///
/// Avoids hardcoding strings throughout the codebase and makes
/// renaming or reorganising assets straightforward.
class AppAssets {
  AppAssets._();

  // Button backgrounds
  static const String buttonBackground =
      'lib/assets/images/button_background.svg';
  static const String buttonNormal = 'lib/assets/images/button.svg';
  static const String buttonPressed = 'lib/assets/images/button_pressed.svg';

  // Power button
  static const String powerButtonNormal = 'lib/assets/images/power_button.svg';
  static const String powerButtonPressed =
      'lib/assets/images/power_button_pressed.svg';

  // Icons
  static const String fanIcon = 'lib/assets/images/ceiling_fan.svg';
}

/// Centralized theme configuration for the application.
///
/// Usage:
/// ```dart
/// MaterialApp(theme: AppTheme.light, ...)
/// ```
abstract final class AppTheme {
  /// Light colour scheme used throughout the app.
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    fontFamily: 'Galada',
    scaffoldBackgroundColor: AppColors.scaffoldBackground,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primaryMaroon,
      surface: AppColors.scaffoldBackground,
    ),
    iconTheme: const IconThemeData(color: AppColors.primaryMaroon),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: AppColors.primaryMaroon,
      contentTextStyle: const TextStyle(
        fontFamily: 'Galada',
        fontWeight: FontWeight.bold,
        color: AppColors.white,
      ),
    ),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
  );
}
