import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/cupertino.dart' show CupertinoTheme;
import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart'
    show ListView, MaterialApp, Scaffold, Scrollable, ValueKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

import 'package:arcis/main.dart';
import 'package:arcis/models/survey_connection.dart';
import 'package:arcis/models/survey_floor.dart';
import 'package:arcis/models/survey_node.dart';
import 'package:arcis/models/survey_route.dart';
import 'package:arcis/widgets/route_guidance_overlay.dart';
import 'package:arcis/widgets/survey_map_preview.dart';
import 'package:arcis/screens/route_navigation_page.dart';

void main() {
  testWidgets('survey screen shows floor and node counter', (tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('FLOOR 5  •  NODES 0'), findsOneWidget);
    expect(find.text('Remove last node'), findsOneWidget);
    expect(find.byType(Scaffold), findsOneWidget);
  });

  testWidgets('loading a shared survey closes its dialog safely', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('open-route-page')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('route-navigation-page')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-shared-survey')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-shared-survey')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('shared-survey-id-input')),
      '00000000-0000-4000-8000-000000000001',
    );
    await tester.tap(find.byKey(const ValueKey('submit-shared-survey-id')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('route-navigation-page')), findsOneWidget);
    expect(find.text('Loading shared survey...'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('can add and select the next survey floor', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add next floor'));
    await tester.pumpAndSettle();

    expect(find.text('FLOOR 6  •  NODES 0'), findsOneWidget);
    expect(find.text('Floor 6'), findsOneWidget);
  });

  testWidgets('can confirm deletion of an empty floor', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Add next floor'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete selected floor'));
    await tester.pumpAndSettle();

    expect(find.text('Delete Floor 6?'), findsOneWidget);
    await tester.tap(find.text('Delete floor'));
    await tester.pumpAndSettle();

    expect(find.text('FLOOR 5  •  NODES 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('uses a Material scaffold for iOS plugin errors', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await tester.pumpWidget(const MyApp());

      expect(find.byType(CupertinoTheme), findsWidgets);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('survey screen fits a compact viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 450);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MyApp());

    expect(tester.takeException(), isNull);
  });

  testWidgets('survey panel can be moved and resized', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    final panelFinder = find.byKey(const ValueKey('survey-control-panel'));
    final initialRect = tester.getRect(panelFinder);
    await tester.drag(
      find.byKey(const ValueKey('survey-panel-drag-handle')),
      const Offset(32, -40),
    );
    await tester.pumpAndSettle();
    final movedRect = tester.getRect(panelFinder);
    expect(movedRect.left, greaterThan(initialRect.left));
    expect(movedRect.top, lessThan(initialRect.top));

    final resizeFinder = find.byKey(
      const ValueKey('survey-panel-resize-handle'),
    );
    await tester.drag(resizeFinder, const Offset(-48, -48));
    await tester.pumpAndSettle();
    final smallerRect = tester.getRect(panelFinder);
    expect(smallerRect.width, lessThan(movedRect.width));
    expect(smallerRect.height, lessThan(movedRect.height));

    await tester.drag(resizeFinder, const Offset(48, 48));
    await tester.pumpAndSettle();
    final largerRect = tester.getRect(panelFinder);
    expect(largerRect.width, greaterThan(smallerRect.width));
    expect(largerRect.height, greaterThan(smallerRect.height));
    expect(tester.takeException(), isNull);
  });

  test('survey node exports stable metadata and coordinates', () {
    final node = SurveyNode(
      id: 'node-7',
      name: 'North entrance',
      type: SurveyNodeType.entrance,
      floor: 5,
      worldPosition: vm.Vector3(1.25, -0.4, 3.5),
      cloudAnchorId: 'cloud-anchor-123',
    );

    expect(node.toJson(), {
      'id': 'node-7',
      'name': 'North entrance',
      'type': 'entrance',
      'floor': 5,
      'cloudAnchorId': 'cloud-anchor-123',
      'worldPosition': {'x': 1.25, 'y': -0.4, 'z': 3.5},
    });
  });

  test('survey node restores coordinates from a Supabase row', () {
    final node = SurveyNode.fromDatabaseRow({
      'id': 'node-7',
      'name': 'North entrance',
      'type': 'entrance',
      'floor': 5,
      'x': 1.25,
      'y': -0.4,
      'z': 3.5,
      'cloud_anchor_id': 'cloud-anchor-123',
    });

    expect(node.toJson(), {
      'id': 'node-7',
      'name': 'North entrance',
      'type': 'entrance',
      'floor': 5,
      'cloudAnchorId': 'cloud-anchor-123',
      'worldPosition': {'x': 1.25, 'y': -0.4, 'z': 3.5},
    });
    expect(node.copyWith(clearCloudAnchorId: true).cloudAnchorId, isNull);
  });

  test('survey floor restores its number and name from a Supabase row', () {
    final floor = SurveyFloor.fromDatabaseRow({'floor': 6, 'name': 'Floor 6'});

    expect(floor.number, 6);
    expect(floor.name, 'Floor 6');
    expect(floor.toDatabaseRow('survey-1'), {
      'survey_id': 'survey-1',
      'floor': 6,
      'name': 'Floor 6',
    });
  });

  test('survey connection matches undirected pairs and exports endpoints', () {
    const connection = SurveyConnection(
      id: 'connection-1',
      nodeAId: 'node-1',
      nodeBId: 'node-2',
    );

    expect(connection.connects('node-1', 'node-2'), isTrue);
    expect(connection.connects('node-2', 'node-1'), isTrue);
    expect(connection.connects('node-1', 'node-3'), isFalse);
    expect(connection.toJson(), {
      'id': 'connection-1',
      'nodeAId': 'node-1',
      'nodeBId': 'node-2',
      'type': 'corridor',
    });
  });

  test('cross-floor route uses connector type instead of AR origins', () {
    final nodes = [
      _routeNode('lobby', 'Lobby', 0, 0, floor: 1),
      _routeNode('stairs-lower', 'Stairs lower', 1, 0, floor: 1),
      _routeNode('stairs-upper', 'Stairs upper', 1000, 1000, floor: 2),
      _routeNode('office', 'Office', 1001, 1000, floor: 2),
    ];
    final connections = [
      _routeConnection('lobby', 'stairs-lower'),
      SurveyConnection(
        id: 'stairs',
        nodeAId: 'stairs-lower',
        nodeBId: 'stairs-upper',
        type: SurveyConnectionType.stairs,
      ),
      _routeConnection('stairs-upper', 'office'),
      _routeConnection('lobby', 'office'),
    ];

    final route = calculateShortestSurveyRoute(
      nodes: nodes,
      connections: connections,
      startNodeId: 'lobby',
      destinationNodeId: 'office',
    );

    expect(route?.nodes.map((node) => node.id), [
      'lobby',
      'stairs-lower',
      'stairs-upper',
      'office',
    ]);
    expect(route?.distanceMeters, 6.375);
    expect(route?.directions, [
      'Start at Lobby on Floor 1.',
      'Walk from Lobby to Stairs lower on Floor 1.',
      'Take the stairs from Floor 1 to Floor 2.',
      'Walk from Stairs upper to Office on Floor 2.',
      'Arrive at Office on Floor 2.',
    ]);
  });

  test('survey route chooses the shortest connected path', () {
    final nodes = [
      _routeNode('start', 'Start', 0, 0),
      _routeNode('near', 'Near', 1, 0),
      _routeNode('far', 'Far', 0, 3),
      _routeNode('end', 'End', 3, 0),
      _routeNode('isolated', 'Isolated', 8, 0),
    ];
    final connections = [
      _routeConnection('start', 'near'),
      _routeConnection('near', 'end'),
      _routeConnection('start', 'far'),
      _routeConnection('far', 'end'),
    ];

    final route = calculateShortestSurveyRoute(
      nodes: nodes,
      connections: connections,
      startNodeId: 'start',
      destinationNodeId: 'end',
    );
    final missingRoute = calculateShortestSurveyRoute(
      nodes: nodes,
      connections: connections,
      startNodeId: 'start',
      destinationNodeId: 'isolated',
    );

    expect(route?.nodes.map((node) => node.id), ['start', 'near', 'end']);
    expect(route?.distanceMeters, 3);
    expect(missingRoute, isNull);
  });

  testWidgets('camera guidance shows only the destination and direction', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteGuidanceOverlay(
            destinationName: 'North entrance',
            bearingRadians: 0.5,
            distanceMeters: 3.2,
            onStop: () {},
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey('camera-direction-arrow')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('camera-only-guidance')), findsOneWidget);
    expect(find.text('North entrance · 3.2 m'), findsOneWidget);
    expect(find.text('ROUTE STEPS'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route page handles waypoint selection and anchoring', (
    tester,
  ) async {
    final nodes = [
      _routeNode('start', 'Lobby', 0, 0, floor: 2),
      _routeNode('end', 'Reception', 3, 0, floor: 2),
      _routeNode('floor-5', 'Upper hall', 8, 0, floor: 5),
    ];
    final connections = [_routeConnection('start', 'end')];
    final route = calculateShortestSurveyRoute(
      nodes: nodes,
      connections: connections,
      startNodeId: 'start',
      destinationNodeId: 'end',
    )!;
    var anchoredNodeId = '';
    var didNavigate = false;
    int? selectedFloor;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteNavigationPage(
            nodes: nodes,
            surveyId: 'shareable-survey-id',
            floorNumbers: const [2, 5],
            connections: connections,
            route: route,
            startNodeId: 'start',
            startFloor: 2,
            destinationNodeId: 'end',
            unanchoredNodeIds: const {'end'},
            message: null,
            canStartNavigation: true,
            onStartChanged: (_) {},
            onStartFloorChanged: (floor) => selectedFloor = floor,
            onDestinationChanged: (_) {},
            onFindRoute: () {},
            onStartNavigation: () => didNavigate = true,
            onReanchorNode: (nodeId) => anchoredNodeId = nodeId,
            onBack: () {},
            onCopySurveyId: () {},
            onOpenSurveyId: () {},
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('route-navigation-page')), findsOneWidget);
    expect(find.text('Plan a route'), findsOneWidget);
    expect(find.byKey(const ValueKey('active-survey-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('copy-survey-id')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-shared-survey')), findsOneWidget);
    expect(
      find.text(
        'Your starting point is chosen from this floor. The destination can be on any connected floor.',
      ),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const ValueKey('current-floor-2')));
    await tester.tap(find.byKey(const ValueKey('current-floor-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Floor 5').last);
    expect(selectedFloor, 5);
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
      find.byKey(const ValueKey('anchor-route-end')),
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    expect(find.text('ANCHOR THESE WAYPOINTS IN THE CAMERA'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('anchor-route-end')));
    expect(anchoredNodeId, 'end');
    expect(didNavigate, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('route page starts camera navigation for anchored waypoints', (
    tester,
  ) async {
    final nodes = [
      _routeNode('start', 'Lobby', 0, 0),
      _routeNode('end', 'Reception', 3, 0),
    ];
    final connections = [_routeConnection('start', 'end')];
    final route = calculateShortestSurveyRoute(
      nodes: nodes,
      connections: connections,
      startNodeId: 'start',
      destinationNodeId: 'end',
    )!;
    var didNavigate = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RouteNavigationPage(
            nodes: nodes,
            surveyId: 'shareable-survey-id',
            floorNumbers: const [5],
            connections: connections,
            route: route,
            startNodeId: 'start',
            startFloor: 5,
            destinationNodeId: 'end',
            unanchoredNodeIds: const {},
            message: null,
            canStartNavigation: true,
            onStartChanged: (_) {},
            onStartFloorChanged: (_) {},
            onDestinationChanged: (_) {},
            onFindRoute: () {},
            onStartNavigation: () => didNavigate = true,
            onReanchorNode: (_) {},
            onBack: () {},
            onCopySurveyId: () {},
            onOpenSurveyId: () {},
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('start-camera-navigation')));

    expect(didNavigate, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('camera arrow bearing follows the waypoint direction', () {
    final forwardBearing = RouteGuidanceOverlay.bearingTo(
      cameraPose: vm.Matrix4.identity(),
      targetPosition: vm.Vector3(0, 0, -5),
    );
    final rightBearing = RouteGuidanceOverlay.bearingTo(
      cameraPose: vm.Matrix4.identity(),
      targetPosition: vm.Vector3(5, 0, -5),
    );

    expect(forwardBearing, closeTo(0, 1e-9));
    expect(rightBearing, closeTo(math.pi / 4, 1e-9));
  });

  test('waypoint arrival distance ignores camera height', () {
    final distance = RouteGuidanceOverlay.distanceTo(
      cameraPose: vm.Matrix4.translationValues(0, 1.6, 0),
      targetPosition: vm.Vector3(3, 0, -4),
    );

    expect(distance, closeTo(5, 1e-9));
  });

  testWidgets('survey map renders links and highlights the shortest route', (
    tester,
  ) async {
    final nodes = [
      _routeNode('start', 'Start', 0, 0),
      _routeNode('middle', 'Middle', 1, 0),
      _routeNode('end', 'End', 2, 1),
    ];
    final connections = [
      _routeConnection('start', 'middle'),
      _routeConnection('middle', 'end'),
    ];
    final route = calculateShortestSurveyRoute(
      nodes: nodes,
      connections: connections,
      startNodeId: 'start',
      destinationNodeId: 'end',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SurveyMapPreview(
            nodes: nodes,
            connections: connections,
            route: route,
            startNodeId: 'start',
            destinationNodeId: 'end',
            focusedNodeId: 'middle',
          ),
        ),
      ),
    );

    expect(find.text('FLOOR MAP · RELATIVE X/Z'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

SurveyNode _routeNode(
  String id,
  String name,
  double x,
  double z, {
  int floor = 5,
}) {
  return SurveyNode(
    id: id,
    name: name,
    type: SurveyNodeType.corridor,
    floor: floor,
    worldPosition: vm.Vector3(x, 0, z),
  );
}

SurveyConnection _routeConnection(String firstNodeId, String secondNodeId) {
  return SurveyConnection(
    id: '$firstNodeId-$secondNodeId',
    nodeAId: firstNodeId,
    nodeBId: secondNodeId,
  );
}
