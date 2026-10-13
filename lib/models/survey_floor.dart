class SurveyFloor {
  const SurveyFloor({required this.number, required this.name});

  final int number;
  final String name;

  factory SurveyFloor.fromDatabaseRow(Map<String, dynamic> row) {
    return SurveyFloor(
      number: row['floor'] as int,
      name: row['name'] as String,
    );
  }

  Map<String, Object> toDatabaseRow(String surveyId) => {
    'survey_id': surveyId,
    'floor': number,
    'name': name,
  };
}
