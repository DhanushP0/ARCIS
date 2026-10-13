import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/survey_connection.dart';
import '../models/survey_node.dart';
import '../models/survey_route.dart';

class SurveyMapPreview extends StatelessWidget {
  const SurveyMapPreview({
    required this.nodes,
    required this.connections,
    this.route,
    this.startNodeId,
    this.destinationNodeId,
    this.focusedNodeId,
    super.key,
  });

  final List<SurveyNode> nodes;
  final List<SurveyConnection> connections;
  final SurveyRoute? route;
  final String? startNodeId;
  final String? destinationNodeId;
  final String? focusedNodeId;

  @override
  Widget build(BuildContext context) {
    final routeNodeIds = route?.nodes.map((node) => node.id).toSet() ?? {};
    final routePairs = <String>{};
    final routeNodes = route?.nodes ?? const <SurveyNode>[];
    for (var index = 0; index + 1 < routeNodes.length; index++) {
      routePairs.add(_pairKey(routeNodes[index].id, routeNodes[index + 1].id));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'FLOOR MAP · RELATIVE X/Z',
          style: TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          height: 148,
          child: CustomPaint(
            painter: _SurveyMapPainter(
              nodes: nodes,
              connections: connections,
              routeNodeIds: routeNodeIds,
              routePairs: routePairs,
              startNodeId: startNodeId,
              destinationNodeId: destinationNodeId,
              focusedNodeId: focusedNodeId,
            ),
          ),
        ),
      ],
    );
  }
}

class _SurveyMapPainter extends CustomPainter {
  const _SurveyMapPainter({
    required this.nodes,
    required this.connections,
    required this.routeNodeIds,
    required this.routePairs,
    required this.startNodeId,
    required this.destinationNodeId,
    required this.focusedNodeId,
  });

  final List<SurveyNode> nodes;
  final List<SurveyConnection> connections;
  final Set<String> routeNodeIds;
  final Set<String> routePairs;
  final String? startNodeId;
  final String? destinationNodeId;
  final String? focusedNodeId;

  @override
  void paint(Canvas canvas, Size size) {
    if (nodes.isEmpty) return;

    const inset = 22.0;
    final minX = nodes.map((node) => node.worldPosition.x).reduce(math.min);
    final maxX = nodes.map((node) => node.worldPosition.x).reduce(math.max);
    final minZ = nodes.map((node) => node.worldPosition.z).reduce(math.min);
    final maxZ = nodes.map((node) => node.worldPosition.z).reduce(math.max);
    final spanX = math.max(maxX - minX, 0.1).toDouble();
    final spanZ = math.max(maxZ - minZ, 0.1).toDouble();
    final scale = math.min(
      (size.width - inset * 2) / spanX,
      (size.height - inset * 2) / spanZ,
    );
    final drawingWidth = spanX * scale;
    final drawingHeight = spanZ * scale;
    final offsetX = (size.width - drawingWidth) / 2;
    final offsetY = (size.height - drawingHeight) / 2;
    final positions = <String, Offset>{
      for (final node in nodes)
        node.id: Offset(
          offsetX + (node.worldPosition.x - minX) * scale,
          offsetY + (node.worldPosition.z - minZ) * scale,
        ),
    };

    final baseLine = Paint()
      ..color = Colors.white38
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final routeLine = Paint()
      ..color = const Color(0xFF67E8F9)
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    for (final connection in connections) {
      final start = positions[connection.nodeAId];
      final end = positions[connection.nodeBId];
      if (start == null || end == null) continue;
      final highlighted = routePairs.contains(
        _pairKey(connection.nodeAId, connection.nodeBId),
      );
      canvas.drawLine(start, end, highlighted ? routeLine : baseLine);
    }

    final labelPainter = TextPainter(textDirection: TextDirection.ltr);
    for (var index = 0; index < nodes.length; index++) {
      final node = nodes[index];
      final position = positions[node.id]!;
      final isStart = node.id == startNodeId;
      final isDestination = node.id == destinationNodeId;
      final isOnRoute = routeNodeIds.contains(node.id);
      final isFocused = node.id == focusedNodeId;
      final fill = isStart
          ? const Color(0xFF86EFAC)
          : isDestination
          ? const Color(0xFFFBBF24)
          : isOnRoute
          ? const Color(0xFF67E8F9)
          : const Color(0xFFE2E8F0);

      canvas.drawCircle(position, 10, Paint()..color = fill);
      canvas.drawCircle(
        position,
        10,
        Paint()
          ..color = Colors.black54
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      if (isFocused) {
        canvas.drawCircle(
          position,
          15,
          Paint()
            ..color = const Color(0xFFF97316)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
      labelPainter.text = TextSpan(
        text: '${index + 1}',
        style: const TextStyle(
          color: Color(0xFF071014),
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      );
      labelPainter.layout();
      labelPainter.paint(
        canvas,
        position - Offset(labelPainter.width / 2, labelPainter.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SurveyMapPainter oldDelegate) =>
      oldDelegate.nodes != nodes ||
      oldDelegate.connections != connections ||
      oldDelegate.routeNodeIds != routeNodeIds ||
      oldDelegate.routePairs != routePairs ||
      oldDelegate.startNodeId != startNodeId ||
      oldDelegate.destinationNodeId != destinationNodeId ||
      oldDelegate.focusedNodeId != focusedNodeId;
}

String _pairKey(String firstId, String secondId) {
  final ids = [firstId, secondId]..sort();
  return '${ids.first}:${ids.last}';
}
