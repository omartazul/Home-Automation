// SPDX-License-Identifier: CC-BY-NC-4.0
// Copyright (c) 2025 Md. Omar Faruk Tazul Islam

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../constants.dart';
import '../models.dart';

/// LCD-style device status panel.
///
/// This widget renders:
/// - A dashboard-like LCD layout.
/// - Per-appliance status indicators.
/// - A 9-segment fan speed gauge.
/// - A subtle LCD flicker effect.
class LcdDisplay extends StatefulWidget {
  final LcdData data;

  const LcdDisplay({this.data = const LcdData(), super.key});

  @override
  State<LcdDisplay> createState() => _LcdDisplayState();
}

class _LcdDisplayState extends State<LcdDisplay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flickerCtrl;

  @override
  void initState() {
    super.initState();
    _flickerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..repeat();
  }

  @override
  void dispose() {
    _flickerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // LCD color palette.
    const backlightColor = Color(0xFFFFBF00);
    const segmentColor = Color(0xFF000000);
    final inactiveSegmentColor = Colors.black.withValues(alpha: 0.10);

    return LayoutBuilder(
      builder: (context, constraints) {
        final screenWidth = constraints.maxWidth;
        final outerPadding = screenWidth * 0.06;

        return Container(
          width: double.infinity,
          height: double.infinity,
          margin: EdgeInsets.all(outerPadding),
          decoration: BoxDecoration(
            color: AppColors.primaryMaroon, // Plastic frame
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.6),
                blurRadius: 8,
                offset: const Offset(-2, -2),
              ),
            ],
            border: Border.all(color: Colors.grey.shade500, width: 2),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10.0),
            child: Container(
              width: double.infinity,
              height: double.infinity,
              decoration: BoxDecoration(
                color: backlightColor,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: backlightColor.withValues(alpha: 0.4),
                    blurRadius: 12,
                    spreadRadius: 3,
                  ),
                  BoxShadow(
                    color: backlightColor.withValues(alpha: 0.3),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: AnimatedBuilder(
                animation: _flickerCtrl,
                builder: (context, child) {
                  final flicker =
                      0.95 +
                      (0.05 * math.sin(_flickerCtrl.value * 2 * math.pi));
                  return Opacity(opacity: flicker, child: child);
                },
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final h = constraints.maxHeight;
                    final w = constraints.maxWidth;
                    final bool isPowered = widget.data.powerOn;
                    final bool isFanActive = isPowered && widget.data.fanOn;

                    return Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: w * 0.05,
                        vertical: h * 0.04,
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Top bar.
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  widget.data.deviceName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'Galada',
                                    fontWeight: FontWeight.w900,
                                    color: widget.data.isConnected
                                        ? segmentColor
                                        : inactiveSegmentColor,
                                    fontSize: h * 0.10,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  _LcdIcon(
                                    icon: Icons.wifi_rounded,
                                    isOn: widget.data.isConnected,
                                    color: segmentColor,
                                    inactiveColor: inactiveSegmentColor,
                                    size: h * 0.12,
                                  ),
                                  SizedBox(width: w * 0.04),
                                  _LcdIcon(
                                    icon: Icons.power_settings_new_rounded,
                                    isOn: isPowered,
                                    color: segmentColor,
                                    inactiveColor: inactiveSegmentColor,
                                    size: h * 0.12,
                                  ),
                                ],
                              ),
                            ],
                          ),

                          // Main readout.
                          Expanded(
                            child: Row(
                              children: [
                                // Left panel: fan status.
                                Expanded(
                                  flex: 6,
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(height: h * 0.06),
                                      Padding(
                                        padding: EdgeInsets.only(
                                          left: w * 0.04,
                                        ),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            SvgPicture.asset(
                                              AppAssets.fanIcon,
                                              width: h * 0.35,
                                              height: h * 0.35,
                                              colorFilter: ColorFilter.mode(
                                                isFanActive
                                                    ? segmentColor
                                                    : inactiveSegmentColor,
                                                BlendMode.srcIn,
                                              ),
                                            ),
                                            SizedBox(width: w * 0.05),
                                            _SevenSegmentDigit(
                                              value: !isPowered
                                                  ? null
                                                  : (isFanActive
                                                        ? widget.data.fanSpeed
                                                        : 11),
                                              size: h * 0.45,
                                              color: segmentColor,
                                              inactiveColor:
                                                  inactiveSegmentColor,
                                            ),
                                          ],
                                        ),
                                      ),
                                      SizedBox(height: h * 0.06),
                                      // 9-segment fan gauge.
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: List.generate(9, (index) {
                                          final isActive =
                                              isFanActive &&
                                              widget.data.fanSpeed > index;
                                          return Container(
                                            width: w * 0.035,
                                            height:
                                                h * 0.08 + (index * h * 0.015),
                                            margin: EdgeInsets.only(
                                              right: w * 0.012,
                                            ),
                                            decoration: BoxDecoration(
                                              color: isActive
                                                  ? segmentColor
                                                  : inactiveSegmentColor,
                                              borderRadius:
                                                  BorderRadius.circular(1),
                                            ),
                                          );
                                        }),
                                      ),
                                    ],
                                  ),
                                ),

                                // Right panel: appliance status.
                                Expanded(
                                  flex: 5,
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      _ApplianceIndicator(
                                        icon: Icons.emoji_objects_outlined,
                                        label: 'L1',
                                        isOn: isPowered && widget.data.light1On,
                                        color: segmentColor,
                                        inactiveColor: inactiveSegmentColor,
                                        h: h,
                                      ),
                                      _ApplianceIndicator(
                                        icon: Icons.emoji_objects_outlined,
                                        label: 'L2',
                                        isOn: isPowered && widget.data.light2On,
                                        color: segmentColor,
                                        inactiveColor: inactiveSegmentColor,
                                        h: h,
                                      ),
                                      _ApplianceIndicator(
                                        icon: Icons.electrical_services_rounded,
                                        label: 'PLUG',
                                        isOn: isPowered && widget.data.plugOn,
                                        color: segmentColor,
                                        inactiveColor: inactiveSegmentColor,
                                        h: h,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Renders one LCD icon with active/inactive coloring.
class _LcdIcon extends StatelessWidget {
  final IconData icon;
  final bool isOn;
  final Color color;
  final Color inactiveColor;
  final double size;

  const _LcdIcon({
    required this.icon,
    required this.isOn,
    required this.color,
    required this.inactiveColor,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: size, color: isOn ? color : inactiveColor);
  }
}

/// A custom-drawn 7-segment digital digit.
class _SevenSegmentDigit extends StatelessWidget {
  final int? value;
  final double size;
  final Color color;
  final Color inactiveColor;

  const _SevenSegmentDigit({
    required this.value,
    required this.size,
    required this.color,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    // Standard 7-segment digit bitmasks (A, B, C, D, E, F, G).
    const segments = [
      0x3F, // 0
      0x06, // 1
      0x5B, // 2
      0x4F, // 3
      0x66, // 4
      0x6D, // 5
      0x7D, // 6
      0x07, // 7
      0x7F, // 8
      0x6F, // 9
    ];

    int mask;
    if (value == null) {
      mask = 0x00; // Blank / Off
    } else if (value == 11) {
      mask = 0x71; // 'F'
    } else if (value! >= 0 && value! <= 9) {
      mask = segments[value!];
    } else {
      mask = 0x00;
    }

    return SizedBox(
      width: size * 0.6,
      height: size,
      child: CustomPainterButton(
        mask: mask,
        color: color,
        inactiveColor: inactiveColor,
      ),
    );
  }
}

class CustomPainterButton extends StatelessWidget {
  final int mask;
  final Color color;
  final Color inactiveColor;

  const CustomPainterButton({
    super.key,
    required this.mask,
    required this.color,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SevenSegmentPainter(
        mask: mask,
        activeColor: color,
        inactiveColor: inactiveColor,
      ),
    );
  }
}

class _SevenSegmentPainter extends CustomPainter {
  final int mask;
  final Color activeColor;
  final Color inactiveColor;

  _SevenSegmentPainter({
    required this.mask,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final thickness = w * 0.18;
    final spacing = w * 0.04;

    void drawSegment(int bit, Path path) {
      final paint = Paint()
        ..color = (mask & (1 << bit)) != 0 ? activeColor : inactiveColor
        ..style = PaintingStyle.fill;
      canvas.drawPath(path, paint);
    }

    // Segment A (top).
    drawSegment(
      0,
      Path()
        ..moveTo(spacing, 0)
        ..lineTo(w - spacing, 0)
        ..lineTo(w - spacing - thickness, thickness)
        ..lineTo(spacing + thickness, thickness)
        ..close(),
    );

    // Segment B (top right).
    drawSegment(
      1,
      Path()
        ..moveTo(w, spacing)
        ..lineTo(w, h / 2 - spacing / 2)
        ..lineTo(w - thickness, h / 2 - spacing / 2 - thickness / 2)
        ..lineTo(w - thickness, spacing + thickness)
        ..close(),
    );

    // Segment C (bottom right).
    drawSegment(
      2,
      Path()
        ..moveTo(w, h / 2 + spacing / 2)
        ..lineTo(w, h - spacing)
        ..lineTo(w - thickness, h - spacing - thickness)
        ..lineTo(w - thickness, h / 2 + spacing / 2 + thickness / 2)
        ..close(),
    );

    // Segment D (bottom).
    drawSegment(
      3,
      Path()
        ..moveTo(spacing, h)
        ..lineTo(w - spacing, h)
        ..lineTo(w - spacing - thickness, h - thickness)
        ..lineTo(spacing + thickness, h - thickness)
        ..close(),
    );

    // Segment E (bottom left).
    drawSegment(
      4,
      Path()
        ..moveTo(0, h / 2 + spacing / 2)
        ..lineTo(0, h - spacing)
        ..lineTo(thickness, h - spacing - thickness)
        ..lineTo(thickness, h / 2 + spacing / 2 + thickness / 2)
        ..close(),
    );

    // Segment F (top left).
    drawSegment(
      5,
      Path()
        ..moveTo(0, spacing)
        ..lineTo(0, h / 2 - spacing / 2)
        ..lineTo(thickness, h / 2 - spacing / 2 - thickness / 2)
        ..lineTo(thickness, spacing + thickness)
        ..close(),
    );

    // Segment G (middle).
    drawSegment(
      6,
      Path()
        ..moveTo(spacing + thickness / 2, h / 2)
        ..lineTo(spacing + thickness, h / 2 - thickness / 2)
        ..lineTo(w - spacing - thickness, h / 2 - thickness / 2)
        ..lineTo(w - spacing - thickness / 2, h / 2)
        ..lineTo(w - spacing - thickness, h / 2 + thickness / 2)
        ..lineTo(spacing + thickness, h / 2 + thickness / 2)
        ..close(),
    );
  }

  @override
  bool shouldRepaint(_SevenSegmentPainter old) => old.mask != mask;
}

/// Renders a compact appliance status indicator.
class _ApplianceIndicator extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOn;
  final Color color;
  final Color inactiveColor;
  final double h;

  const _ApplianceIndicator({
    required this.icon,
    required this.label,
    required this.isOn,
    required this.color,
    required this.inactiveColor,
    required this.h,
  });

  @override
  Widget build(BuildContext context) {
    final currentColor = isOn ? color : inactiveColor;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: h * 0.35, color: currentColor),
        SizedBox(height: h * 0.05),
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Galada',
            fontSize: h * 0.12,
            fontWeight: FontWeight.w900,
            color: currentColor,
            letterSpacing: 0.5,
          ),
        ),
        SizedBox(height: h * 0.04),
        // Solid underline to indicate active state.
        Container(
          width: h * 0.22,
          height: h * 0.04,
          decoration: BoxDecoration(
            color: currentColor,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
      ],
    );
  }
}
