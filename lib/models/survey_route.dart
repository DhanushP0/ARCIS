import 'survey_connection.dart';
import 'survey_node.dart';

class SurveyRoute {
  const SurveyRoute({
    required this.nodes,
    required this.distanceMeters,
    required this.directions,
  });

  final List<SurveyNode> nodes;
  final double distanceMeters;
  final List<String> directions;
}

SurveyRoute? calculateShortestSurveyRoute({
  required List<SurveyNode> nodes,
  required List<SurveyConnection> connections,
  required String startNodeId,
  required String destinationNodeId,
  double floorHeightMeters = 3.5,
}) {
  final nodesById = {for (final node in nodes) node.id: node};
  if (!nodesById.containsKey(startNodeId) ||
      !nodesById.containsKey(destinationNodeId)) {
    return null;
  }

  final distances = {for (final node in nodes) node.id: double.infinity};
  final previousNodeIds = <String, String>{};
  final previousConnectionIds = <String, String>{};
  final unvisitedNodeIds = nodesById.keys.toSet();
  distances[startNodeId] = 0;

  while (unvisitedNodeIds.isNotEmpty) {
    final currentNodeId = unvisitedNodeIds.reduce(
      (closestId, candidateId) =>
          distances[candidateId]! < distances[closestId]!
          ? candidateId
          : closestId,
    );
    final currentDistance = distances[currentNodeId]!;
    if (!currentDistance.isFinite) break;
    unvisitedNodeIds.remove(currentNodeId);
    if (currentNodeId == destinationNodeId) break;

    final currentNode = nodesById[currentNodeId]!;
    for (final connection in connections) {
      final neighborId = connection.nodeAId == currentNodeId
          ? connection.nodeBId
          : connection.nodeBId == currentNodeId
          ? connection.nodeAId
          : null;
      if (neighborId == null || !unvisitedNodeIds.contains(neighborId)) {
        continue;
      }
      final neighbor = nodesById[neighborId];
      if (neighbor == null) continue;

      final crossesFloors = currentNode.floor != neighbor.floor;
      if (crossesFloors && connection.type == SurveyConnectionType.corridor) {
        continue;
      }
      if (!crossesFloors && connection.type != SurveyConnectionType.corridor) {
        continue;
      }
      final edgeDistance = crossesFloors
          ? (currentNode.floor - neighbor.floor).abs() *
                floorHeightMeters *
                (connection.type == SurveyConnectionType.stairs ? 1.25 : 1.0)
          : (currentNode.worldPosition - neighbor.worldPosition).length;
      final candidateDistance = currentDistance + edgeDistance;
      if (candidateDistance < distances[neighborId]!) {
        distances[neighborId] = candidateDistance;
        previousNodeIds[neighborId] = currentNodeId;
        previousConnectionIds[neighborId] = connection.id;
      }
    }
  }

  final totalDistance = distances[destinationNodeId]!;
  if (!totalDistance.isFinite) return null;

  final routeNodeIds = <String>[destinationNodeId];
  final routeConnectionIds = <String>[];
  var currentNodeId = destinationNodeId;
  while (currentNodeId != startNodeId) {
    final previousNodeId = previousNodeIds[currentNodeId];
    final connectionId = previousConnectionIds[currentNodeId];
    if (previousNodeId == null || connectionId == null) return null;
    routeConnectionIds.add(connectionId);
    routeNodeIds.add(previousNodeId);
    currentNodeId = previousNodeId;
  }

  final orderedNodeIds = routeNodeIds.reversed.toList();
  final orderedConnectionIds = routeConnectionIds.reversed.toList();
  final routeNodes = orderedNodeIds
      .map((nodeId) => nodesById[nodeId]!)
      .toList();
  final connectionsById = {
    for (final connection in connections) connection.id: connection,
  };
  final directions = <String>[
    'Start at ${routeNodes.first.name} on Floor ${routeNodes.first.floor}.',
  ];
  for (var index = 0; index < orderedConnectionIds.length; index++) {
    final from = routeNodes[index];
    final to = routeNodes[index + 1];
    final connection = connectionsById[orderedConnectionIds[index]]!;
    switch (connection.type) {
      case SurveyConnectionType.corridor:
        directions.add(
          'Walk from ${from.name} to ${to.name} on Floor ${from.floor}.',
        );
      case SurveyConnectionType.stairs:
        directions.add(
          'Take the stairs from Floor ${from.floor} to Floor ${to.floor}.',
        );
      case SurveyConnectionType.elevator:
        directions.add(
          'Take the elevator from Floor ${from.floor} to Floor ${to.floor}.',
        );
    }
  }
  directions.add(
    'Arrive at ${routeNodes.last.name} on Floor ${routeNodes.last.floor}.',
  );

  return SurveyRoute(
    nodes: routeNodes,
    distanceMeters: totalDistance,
    directions: directions,
  );
}
