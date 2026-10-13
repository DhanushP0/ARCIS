import 'package:flutter/material.dart';

import '../models/survey_connection.dart';
import '../models/survey_node.dart';
import '../models/survey_route.dart';

class RouteNavigationPage extends StatelessWidget {
  const RouteNavigationPage({
    required this.nodes,
    required this.surveyId,
    required this.floorNumbers,
    required this.connections,
    required this.route,
    required this.startNodeId,
    required this.startFloor,
    required this.destinationNodeId,
    required this.unanchoredNodeIds,
    required this.message,
    required this.canStartNavigation,
    required this.onStartChanged,
    required this.onStartFloorChanged,
    required this.onDestinationChanged,
    required this.onFindRoute,
    required this.onStartNavigation,
    required this.onReanchorNode,
    required this.onBack,
    required this.onCopySurveyId,
    required this.onOpenSurveyId,
    super.key,
  });

  final List<SurveyNode> nodes;
  final String surveyId;
  final List<int> floorNumbers;
  final List<SurveyConnection> connections;
  final SurveyRoute? route;
  final String? startNodeId;
  final int startFloor;
  final String? destinationNodeId;
  final Set<String> unanchoredNodeIds;
  final String? message;
  final bool canStartNavigation;
  final ValueChanged<String?> onStartChanged;
  final ValueChanged<int?> onStartFloorChanged;
  final ValueChanged<String?> onDestinationChanged;
  final VoidCallback onFindRoute;
  final VoidCallback onStartNavigation;
  final ValueChanged<String> onReanchorNode;
  final VoidCallback onBack;
  final VoidCallback onCopySurveyId;
  final VoidCallback onOpenSurveyId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final startNodes = nodes.where((node) => node.floor == startFloor).toList();

    Widget endpointSelector({
      required String label,
      required String? selectedId,
      required List<SurveyNode> options,
      required ValueChanged<String?> onChanged,
    }) {
      return DropdownButtonFormField<String>(
        key: ValueKey('$label-${selectedId ?? 'empty'}'),
        initialValue: options.any((node) => node.id == selectedId)
            ? selectedId
            : null,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF172329),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
        items: options
            .map(
              (node) => DropdownMenuItem(
                value: node.id,
                child: Text(
                  '${node.name} · Floor ${node.floor}',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: onChanged,
      );
    }

    return Material(
      key: const ValueKey('route-navigation-page'),
      color: const Color(0xFF071014),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 20, 12),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Back to survey',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.alt_route, color: Color(0xFF67E8F9)),
                  const SizedBox(width: 10),
                  Text(
                    'Plan a route',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                children: [
                  Text(
                    'Choose where you are and where you want to go.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: ValueKey('current-floor-$startFloor'),
                    initialValue: floorNumbers.contains(startFloor)
                        ? startFloor
                        : null,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: 'Your current floor',
                      filled: true,
                      fillColor: const Color(0xFF172329),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    items: floorNumbers
                        .map(
                          (floor) => DropdownMenuItem(
                            value: floor,
                            child: Text('Floor $floor'),
                          ),
                        )
                        .toList(),
                    onChanged: onStartFloorChanged,
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Your starting point is chosen from this floor. The destination can be on any connected floor.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 12),
                  endpointSelector(
                    label: 'Starting point',
                    selectedId: startNodeId,
                    options: startNodes,
                    onChanged: onStartChanged,
                  ),
                  const SizedBox(height: 12),
                  endpointSelector(
                    label: 'Destination',
                    selectedId: destinationNodeId,
                    options: nodes,
                    onChanged: onDestinationChanged,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 52,
                    child: FilledButton.icon(
                      key: const ValueKey('find-route-on-route-page'),
                      onPressed:
                          startNodeId == null ||
                              destinationNodeId == null ||
                              connections.isEmpty
                          ? null
                          : onFindRoute,
                      icon: const Icon(Icons.search),
                      label: const Text('Find route'),
                    ),
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      message!,
                      style: const TextStyle(color: Color(0xFFFBBF24)),
                    ),
                  ],
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF172329),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SHARED SURVEY',
                          style: TextStyle(
                            color: Color(0xFF67E8F9),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8,
                          ),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          surveyId,
                          key: const ValueKey('active-survey-id'),
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton.icon(
                              key: const ValueKey('copy-survey-id'),
                              onPressed: surveyId.isEmpty
                                  ? null
                                  : onCopySurveyId,
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy ID to share'),
                            ),
                            OutlinedButton.icon(
                              key: const ValueKey('open-shared-survey'),
                              onPressed: onOpenSurveyId,
                              icon: const Icon(Icons.input),
                              label: const Text('Open shared survey'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Open this same survey ID on the other device to load its saved start, destination, route, and AR anchors.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                  if (route != null) ...[
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF172329),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${route!.distanceMeters.toStringAsFixed(1)} m',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF67E8F9),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${route!.nodes.first.name} → ${route!.nodes.last.name}',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 12),
                          ...route!.nodes.asMap().entries.map(
                            (entry) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              leading: Icon(
                                entry.key == 0
                                    ? Icons.trip_origin
                                    : entry.key == route!.nodes.length - 1
                                    ? Icons.flag
                                    : Icons.location_on_outlined,
                                color: const Color(0xFF67E8F9),
                              ),
                              title: Text(entry.value.name),
                              subtitle: Text(
                                entry.value.cloudAnchorId == null
                                    ? 'Floor ${entry.value.floor}'
                                    : 'Floor ${entry.value.floor} · Saved AR anchor',
                              ),
                              trailing:
                                  unanchoredNodeIds.contains(entry.value.id)
                                  ? const Icon(
                                      Icons.location_searching,
                                      color: Color(0xFFFBBF24),
                                    )
                                  : entry.value.cloudAnchorId != null
                                  ? const Icon(
                                      Icons.cloud_done,
                                      color: Color(0xFF86EFAC),
                                    )
                                  : const Icon(
                                      Icons.check_circle,
                                      color: Color(0xFF86EFAC),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (unanchoredNodeIds.isNotEmpty) ...[
                      const SizedBox(height: 18),
                      const Text(
                        'ANCHOR THESE WAYPOINTS IN THE CAMERA',
                        style: TextStyle(
                          color: Color(0xFFFBBF24),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ...route!.nodes
                          .where((node) => unanchoredNodeIds.contains(node.id))
                          .map(
                            (node) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(
                                Icons.location_searching,
                                color: Color(0xFFFBBF24),
                              ),
                              title: Text(node.name),
                              subtitle: Text('Floor ${node.floor}'),
                              trailing: FilledButton.tonal(
                                key: ValueKey('anchor-route-${node.id}'),
                                onPressed: () => onReanchorNode(node.id),
                                child: const Text('Anchor'),
                              ),
                            ),
                          ),
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Tap Anchor, then tap that waypoint’s real location in the camera view.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 56,
                      child: FilledButton.icon(
                        key: const ValueKey('start-camera-navigation'),
                        onPressed:
                            canStartNavigation && unanchoredNodeIds.isEmpty
                            ? onStartNavigation
                            : null,
                        icon: const Icon(Icons.navigation),
                        label: const Text('Start camera navigation'),
                      ),
                    ),
                    if (unanchoredNodeIds.isEmpty && !canStartNavigation)
                      const Padding(
                        padding: EdgeInsets.only(top: 10),
                        child: Text(
                          'Start the AR camera before beginning navigation.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
