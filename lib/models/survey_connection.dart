enum SurveyConnectionType { corridor, stairs, elevator }

class SurveyConnection {
  const SurveyConnection({
    required this.id,
    required this.nodeAId,
    required this.nodeBId,
    this.type = SurveyConnectionType.corridor,
  });

  final String id;
  final String nodeAId;
  final String nodeBId;
  final SurveyConnectionType type;

  factory SurveyConnection.fromDatabaseRow(Map<String, dynamic> row) {
    return SurveyConnection(
      id: row['id'] as String,
      nodeAId: row['node_a_id'] as String,
      nodeBId: row['node_b_id'] as String,
      type: SurveyConnectionType.values.firstWhere(
        (type) => type.name == row['connection_type'],
        orElse: () => SurveyConnectionType.corridor,
      ),
    );
  }

  Map<String, Object> toJson() => {
    'id': id,
    'nodeAId': nodeAId,
    'nodeBId': nodeBId,
    'type': type.name,
  };

  bool connects(String firstNodeId, String secondNodeId) =>
      (nodeAId == firstNodeId && nodeBId == secondNodeId) ||
      (nodeAId == secondNodeId && nodeBId == firstNodeId);
}
