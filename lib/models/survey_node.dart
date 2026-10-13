import 'package:vector_math/vector_math_64.dart' as vm;

enum SurveyNodeType {
  entrance,
  corridor,
  junction,
  room,
  staircase,
  elevator,
  landmark,
}

class SurveyNode {
  const SurveyNode({
    required this.id,
    required this.name,
    required this.type,
    required this.floor,
    required this.worldPosition,
    this.cloudAnchorId,
  });

  final String id;
  final String name;
  final SurveyNodeType type;
  final int floor;
  final vm.Vector3 worldPosition;
  final String? cloudAnchorId;

  factory SurveyNode.fromDatabaseRow(Map<String, dynamic> row) {
    return SurveyNode(
      id: row['id'] as String,
      name: row['name'] as String,
      type: SurveyNodeType.values.firstWhere(
        (type) => type.name == row['type'],
      ),
      floor: row['floor'] as int,
      worldPosition: vm.Vector3(
        (row['x'] as num).toDouble(),
        (row['y'] as num).toDouble(),
        (row['z'] as num).toDouble(),
      ),
      cloudAnchorId: row['cloud_anchor_id'] as String?,
    );
  }

  Map<String, Object?> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'floor': floor,
      'cloudAnchorId': cloudAnchorId,
      'worldPosition': {
        'x': worldPosition.x,
        'y': worldPosition.y,
        'z': worldPosition.z,
      },
    };
  }

  SurveyNode copyWith({
    String? name,
    SurveyNodeType? type,
    String? cloudAnchorId,
    bool clearCloudAnchorId = false,
  }) {
    return SurveyNode(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      floor: floor,
      worldPosition: worldPosition,
      cloudAnchorId: clearCloudAnchorId
          ? null
          : cloudAnchorId ?? this.cloudAnchorId,
    );
  }
}
