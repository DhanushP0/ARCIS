import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/survey_connection.dart';
import '../models/survey_floor.dart';
import '../models/survey_node.dart';
import 'supabase_api.dart';

class SurveyRepository {
  SurveyRepository({required this.surveyId}) : _client = SupabaseApi.client;

  final String surveyId;
  final SupabaseClient? _client;

  bool get isEnabled => _client != null;

  Future<List<SurveyFloor>> fetchFloors() async {
    final client = _client;
    if (client == null) return [];
    final rows = await client
        .from('survey_floors')
        .select()
        .eq('survey_id', surveyId)
        .order('floor');
    return rows.map((row) => SurveyFloor.fromDatabaseRow(row)).toList();
  }

  Future<void> upsertFloor(SurveyFloor floor) async {
    final client = _client;
    if (client == null) return;
    await client.from('survey_floors').upsert(floor.toDatabaseRow(surveyId));
  }

  Future<void> deleteFloor(int floorNumber) async {
    final client = _client;
    if (client == null) return;
    await client
        .from('survey_floors')
        .delete()
        .eq('survey_id', surveyId)
        .eq('floor', floorNumber);
  }

  Future<List<SurveyNode>> fetchNodes() async {
    final client = _client;
    if (client == null) return [];
    final rows = await client
        .from('survey_nodes')
        .select()
        .eq('survey_id', surveyId)
        .order('created_at');
    return rows.map((row) => SurveyNode.fromDatabaseRow(row)).toList();
  }

  Future<List<SurveyConnection>> fetchConnections() async {
    final client = _client;
    if (client == null) return [];
    final rows = await client
        .from('survey_connections')
        .select()
        .eq('survey_id', surveyId)
        .order('created_at');
    return rows.map((row) => SurveyConnection.fromDatabaseRow(row)).toList();
  }

  Future<void> upsertNode(SurveyNode node) async {
    final client = _client;
    if (client == null) {
      throw StateError('Supabase is not initialized; waypoint was not saved.');
    }
    final position = node.worldPosition;
    await client.from('survey_nodes').upsert({
      'id': node.id,
      'survey_id': surveyId,
      'name': node.name,
      'type': node.type.name,
      'floor': node.floor,
      'x': position.x,
      'y': position.y,
      'z': position.z,
      'cloud_anchor_id': node.cloudAnchorId,
    });
  }

  Future<void> upsertConnection(SurveyConnection connection) async {
    final client = _client;
    if (client == null) return;
    await client.from('survey_connections').upsert({
      'id': connection.id,
      'survey_id': surveyId,
      'node_a_id': connection.nodeAId,
      'node_b_id': connection.nodeBId,
      'connection_type': connection.type.name,
    });
  }

  Future<void> deleteConnection(String connectionId) async {
    final client = _client;
    if (client == null) return;
    await client
        .from('survey_connections')
        .delete()
        .eq('survey_id', surveyId)
        .eq('id', connectionId);
  }

  Future<void> deleteNode(String nodeId) async {
    final client = _client;
    if (client == null) return;
    await client
        .from('survey_nodes')
        .delete()
        .eq('survey_id', surveyId)
        .eq('id', nodeId);
  }

  Future<void> clearSurvey() async {
    final client = _client;
    if (client == null) return;
    await client.from('survey_connections').delete().eq('survey_id', surveyId);
    await client.from('survey_nodes').delete().eq('survey_id', surveyId);
  }
}
