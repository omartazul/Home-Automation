// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../constants.dart';

/// A reusable row container that renders [children] over an SVG background
/// and ensures each button cell is square based on the container height.
class ControlRow extends StatelessWidget {
  final String semanticLabel;
  final List<Widget> children;
  final MainAxisAlignment alignment;

  const ControlRow({
    required this.semanticLabel,
    required this.children,
    this.alignment = MainAxisAlignment.spaceEvenly,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      child: Container(
        key: ValueKey(semanticLabel),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final buttonSize = constraints.maxHeight;

            return Row(
              mainAxisAlignment: alignment,
              children: children.map((child) {
                return SizedBox(
                  width: buttonSize,
                  height: buttonSize,
                  child: Stack(
                    children: [
                      // SVG background tile.
                      SvgPicture.asset(
                        AppAssets.buttonBackground,
                        width: buttonSize,
                        height: buttonSize,
                        fit: BoxFit.fill,
                      ),
                      Center(child: child),
                    ],
                  ),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}

/// A button that provides visual and haptic feedback when pressed.
///
/// Supports both Material [iconData] and SVG [svgIconAsset] overlays.
/// The button size is derived from the parent's constraints via [LayoutBuilder].
class MomentaryButton extends StatefulWidget {
  final String name;

  /// SVG asset path for the button body in its normal state.
  final String asset;

  /// SVG asset path for the button body in its pressed state.
  final String assetPressed;

  /// Optional Material icon displayed on top of the button body.
  final IconData? iconData;

  /// Optional SVG icon displayed on top of the button body.
  final String? svgIconAsset;

  final Color normalIconColor;
  final Color pressedIconColor;

  /// Icon size as a fraction of the button cell (0.0–1.0).
  final double iconScale;
  final double pressedIconScale;

  /// Called once per complete tap (finger down then up).
  final VoidCallback? onTap;

  const MomentaryButton({
    required this.name,
    this.asset = AppAssets.buttonNormal,
    this.assetPressed = AppAssets.buttonPressed,
    this.iconData,
    this.svgIconAsset,
    this.normalIconColor = AppColors.primaryMaroon,
    this.pressedIconColor = AppColors.iconDark,
    this.iconScale = 0.7,
    this.pressedIconScale = 0.6,
    this.onTap,
    super.key,
  });

  @override
  State<MomentaryButton> createState() => _MomentaryButtonState();
}

class _MomentaryButtonState extends State<MomentaryButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  void _onTapDown(_) {
    HapticFeedback.lightImpact();
    _setPressed(true);
  }

  void _onTapUp(_) {
    HapticFeedback.lightImpact();
    _setPressed(false);
    widget.onTap?.call();
  }

  void _onTapCancel() {
    _setPressed(false);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Button occupies 60% of the background cell height.
        final size = constraints.maxHeight * 0.6;
        final currentScale = _pressed
            ? widget.pressedIconScale
            : widget.iconScale;

        return Semantics(
          label: widget.name,
          button: true,
          child: GestureDetector(
            onTapDown: _onTapDown,
            onTapUp: _onTapUp,
            onTapCancel: _onTapCancel,
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Button body.
                  SvgPicture.asset(
                    _pressed ? widget.assetPressed : widget.asset,
                    width: size,
                    height: size,
                    fit: BoxFit.fill,
                  ),

                  // Material icon overlay.
                  if (widget.iconData != null)
                    Icon(
                      widget.iconData,
                      size: currentScale * size,
                      color: _pressed
                          ? widget.pressedIconColor
                          : widget.normalIconColor,
                    ),

                  // SVG icon overlay.
                  if (widget.svgIconAsset != null)
                    SvgPicture.asset(
                      widget.svgIconAsset!,
                      width: currentScale * size,
                      height: currentScale * size,
                      colorFilter: ColorFilter.mode(
                        _pressed
                            ? widget.pressedIconColor
                            : widget.normalIconColor,
                        BlendMode.srcIn,
                      ),
                      fit: BoxFit.contain,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Decorative signature footer displayed at the bottom of the screen.
class SignatureFooter extends StatelessWidget {
  final String text;

  const SignatureFooter({required this.text, super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'signature_container',
      child: Container(
        key: const ValueKey('signature_container'),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fontSize = (constraints.maxHeight * 0.55).clamp(14.0, 32.0);
            return Center(
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: 'Sacramento',
                  color: AppColors.primaryMaroon,
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
