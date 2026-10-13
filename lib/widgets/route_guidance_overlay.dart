import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

class RouteGuidanceOverlay extends StatelessWidget {
  const RouteGuidanceOverlay({
    required this.destinationName,
    required this.bearingRadians,
    required this.distanceMeters,
    required this.onStop,
    super.key,
  });

  final String destinationName;
  final double? bearingRadians;
  final double? distanceMeters;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final bearing = bearingRadians;
    final distance = distanceMeters;
    final hasCameraTarget = bearing != null && distance != null;

    return SafeArea(
      child: Stack(
        key: const ValueKey('camera-only-guidance'),
        fit: StackFit.expand,
        children: [
          Center(
            child: hasCameraTarget
                ? Transform.rotate(
                    angle: bearing,
                    child: const Icon(
                      Icons.navigation,
                      key: ValueKey('camera-direction-arrow'),
                      size: 104,
                      color: Color(0xFF67E8F9),
                      shadows: [Shadow(color: Colors.black87, blurRadius: 18)],
                    ),
                  )
                : const Icon(
                    Icons.location_searching,
                    key: ValueKey('camera-target-unavailable'),
                    size: 88,
                    color: Color(0xFFFBBF24),
                    shadows: [Shadow(color: Colors.black87, blurRadius: 18)],
                  ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xD9071014),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.place, color: Color(0xFF67E8F9)),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 180),
                      child: Text(
                        hasCameraTarget
                            ? '$destinationName · ${distance.toStringAsFixed(1)} m'
                            : destinationName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Stop guidance',
                      onPressed: onStop,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static double? bearingTo({
    required vm.Matrix4 cameraPose,
    required vm.Vector3 targetPosition,
  }) {
    final cameraPosition = cameraPose.getTranslation();
    final dx = targetPosition.x - cameraPosition.x;
    final dz = targetPosition.z - cameraPosition.z;
    final distanceSquared = dx * dx + dz * dz;
    if (!distanceSquared.isFinite || distanceSquared < 1e-8) return null;

    final storage = cameraPose.storage;
    final rightX = storage[0];
    final rightZ = storage[2];
    final forwardX = -storage[8];
    final forwardZ = -storage[10];
    final right = dx * rightX + dz * rightZ;
    final forward = dx * forwardX + dz * forwardZ;
    if (!right.isFinite || !forward.isFinite) return null;
    return math.atan2(right, forward);
  }

  static double distanceTo({
    required vm.Matrix4 cameraPose,
    required vm.Vector3 targetPosition,
  }) {
    final cameraPosition = cameraPose.getTranslation();
    return math.sqrt(
      math.pow(targetPosition.x - cameraPosition.x, 2).toDouble() +
          math.pow(targetPosition.z - cameraPosition.z, 2).toDouble(),
    );
  }
}
