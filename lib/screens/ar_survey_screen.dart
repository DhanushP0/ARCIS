import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:ar_flutter_plugin_plus/datatypes/config_planedetection.dart';
import 'package:ar_flutter_plugin_plus/datatypes/hittest_result_types.dart';
import 'package:ar_flutter_plugin_plus/datatypes/node_types.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_anchor_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_location_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_object_manager.dart';
import 'package:ar_flutter_plugin_plus/managers/ar_session_manager.dart';
import 'package:ar_flutter_plugin_plus/models/ar_anchor.dart';
import 'package:ar_flutter_plugin_plus/models/ar_hittest_result.dart';
import 'package:ar_flutter_plugin_plus/models/ar_node.dart';
import 'package:ar_flutter_plugin_plus/widgets/ar_view.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:uuid/uuid.dart';

import '../models/survey_node.dart';
import '../models/survey_connection.dart';
import '../models/survey_floor.dart';
import '../models/survey_route.dart';
import 'route_navigation_page.dart';
import '../services/survey_repository.dart';
import '../services/supabase_api.dart';
import '../widgets/survey_map_preview.dart';
import '../widgets/route_guidance_overlay.dart';

class ArSurveyScreen extends StatefulWidget {
  const ArSurveyScreen({super.key});

  @override
  State<ArSurveyScreen> createState() => _ArSurveyScreenState();
}

class _ArSurveyScreenState extends State<ArSurveyScreen> {
  static const _surveyIdPreferenceKey = 'arcis.activeSurveyId';
  static const _markerAssetUri = 'assets/ar/survey_marker.glb';

  ARSessionManager? _sessionManager;
  ARObjectManager? _objectManager;
  ARAnchorManager? _anchorManager;
  final Map<String, _PendingCloudAnchorResolution>
  _pendingCloudAnchorResolutions = {};
  final Map<String, Timer> _cloudAnchorUploadTimers = {};
  final Map<String, String> _cloudAnchorUploadNodeIds = {};
  final List<_PlacedSurveyNode> _placedNodes = [];
  final List<SurveyConnection> _connections = [];
  final List<SurveyFloor> _floors = [];
  late SurveyRepository _repository;
  String _activeSurveyId = '';
  int _activeFloor = 5;
  int _nextNodeNumber = 1;
  bool _isPlacing = false;
  bool _isLoadingSurvey = true;
  bool _isConnecting = false;
  bool _isRoutePageOpen = false;
  String? _connectionStartNodeId;
  String? _nodeToReanchorId;
  String? _routeStartNodeId;
  String? _routeDestinationNodeId;
  int _routeStartFloor = 5;
  SurveyRoute? _activeRoute;
  String? _routeMessage;
  bool _isGuidingRoute = false;
  bool _isAutoGuidingRoute = false;
  bool _isResolvingRouteAnchors = false;
  bool _isCheckingGuidancePosition = false;
  int _navigationStepIndex = 0;
  double? _guidanceBearingRadians;
  double? _guidanceDistanceMeters;
  Timer? _guidanceTimer;
  Offset? _panelOffset;
  Size? _panelSize;
  String _status = 'Preparing survey...';

  @override
  void initState() {
    super.initState();
    _initializeSurvey();
  }

  Future<void> _initializeSurvey({String? requestedSurveyId}) async {
    await SupabaseApi.ready;

    var surveyId = requestedSurveyId ?? const Uuid().v4();
    var canRememberSurveyId = false;
    try {
      final preferences = await SharedPreferences.getInstance();
      final savedSurveyId = requestedSurveyId == null
          ? preferences.getString(_surveyIdPreferenceKey)
          : null;
      if (savedSurveyId != null && savedSurveyId.isNotEmpty) {
        surveyId = savedSurveyId;
        canRememberSurveyId = true;
      } else {
        canRememberSurveyId = await preferences.setString(
          _surveyIdPreferenceKey,
          surveyId,
        );
      }
    } catch (error) {
      debugPrint('ARCIS survey ID persistence failed: $error');
    }

    _activeSurveyId = surveyId;
    if (mounted) setState(() {});
    _repository = SurveyRepository(surveyId: surveyId);
    try {
      final nodes = await _repository.fetchNodes();
      var floorsFailedToLoad = false;
      List<SurveyFloor> floors;
      try {
        floors = await _repository.fetchFloors();
        if (floors.isEmpty) {
          final floorNumbers = {5, ...nodes.map((node) => node.floor)}.toList()
            ..sort();
          floors = floorNumbers
              .map(
                (number) => SurveyFloor(number: number, name: 'Floor $number'),
              )
              .toList();
          for (final floor in floors) {
            await _repository.upsertFloor(floor);
          }
        }
      } catch (error) {
        floorsFailedToLoad = true;
        debugPrint('ARCIS floor load failed: $error');
        final floorNumbers = {5, ...nodes.map((node) => node.floor)}.toList()
          ..sort();
        floors = floorNumbers
            .map((number) => SurveyFloor(number: number, name: 'Floor $number'))
            .toList();
      }
      List<SurveyConnection> connections = [];
      var connectionsFailedToLoad = false;
      try {
        connections = await _repository.fetchConnections();
      } catch (error) {
        connectionsFailedToLoad = true;
        debugPrint('ARCIS connection load failed: $error');
      }
      if (!mounted) return;
      var largestNodeNumber = 0;
      final restoredNodes = nodes.map((node) {
        final match = RegExp(r'^node-(\d+)$').firstMatch(node.id);
        final nodeNumber = int.tryParse(match?.group(1) ?? '');
        if (nodeNumber != null && nodeNumber > largestNodeNumber) {
          largestNodeNumber = nodeNumber;
        }
        return _PlacedSurveyNode(node: node);
      }).toList();
      setState(() {
        _placedNodes.addAll(restoredNodes);
        _floors
          ..clear()
          ..addAll(floors);
        _connections.addAll(connections);
        _activeFloor = floors.any((floor) => floor.number == 5)
            ? 5
            : floors.first.number;
        _routeStartFloor = _activeFloor;
        _nextNodeNumber = largestNodeNumber + 1;
        _isLoadingSurvey = false;
        _status = !canRememberSurveyId
            ? 'Survey ID is temporary. Saved work may not reopen next time.'
            : floorsFailedToLoad
            ? 'Floor setup could not sync. Apply the updated Supabase schema to save floors.'
            : connectionsFailedToLoad
            ? 'Nodes loaded. Apply the connections schema in Supabase to sync links.'
            : !_repository.isEnabled
            ? 'Database unavailable. New nodes will stay on this device session.'
            : nodes.isEmpty
            ? 'New survey ready. Move your iPhone to scan the floor.'
            : 'Loaded ${nodes.length} saved nodes. Scan surfaces to add AR markers.';
      });
    } catch (error) {
      debugPrint('ARCIS Supabase load failed: $error');
      if (!mounted) return;
      setState(() {
        _isLoadingSurvey = false;
        _status =
            'Could not load saved nodes. You can still start a new survey.';
      });
    }
  }

  @override
  void dispose() {
    _guidanceTimer?.cancel();
    for (final timer in _cloudAnchorUploadTimers.values) {
      timer.cancel();
    }
    _sessionManager?.dispose();
    super.dispose();
  }

  bool get _canAutoGuideActiveRoute {
    final route = _activeRoute;
    if (route == null) return false;
    return route.nodes.every(
      (routeNode) => _placedNodes.any(
        (placedNode) =>
            placedNode.node.id == routeNode.id &&
            (placedNode.anchor != null ||
                placedNode.node.cloudAnchorId != null),
      ),
    );
  }

  void _resetRouteGuidance() {
    _guidanceTimer?.cancel();
    _isGuidingRoute = false;
    _isAutoGuidingRoute = false;
    _navigationStepIndex = 0;
    _guidanceBearingRadians = null;
    _guidanceDistanceMeters = null;
    unawaited(_restoreSurveyMarkers());
  }

  void _movePanel(Offset delta, Size viewport, Size panel) {
    final current =
        _panelOffset ?? Offset(0, math.max(0, viewport.height - panel.height));
    setState(() {
      _panelOffset = Offset(
        (current.dx + delta.dx).clamp(0.0, viewport.width - panel.width),
        (current.dy + delta.dy).clamp(0.0, viewport.height - panel.height),
      );
    });
  }

  void _resizePanel(Offset delta, Size viewport, Size currentPanel) {
    const minWidth = 240.0;
    const minHeight = 180.0;
    setState(() {
      _panelSize = Size(
        (currentPanel.width + delta.dx).clamp(
          math.min(minWidth, viewport.width),
          viewport.width,
        ),
        (currentPanel.height + delta.dy).clamp(
          math.min(minHeight, viewport.height),
          viewport.height,
        ),
      );
    });
  }

  void _selectFloor(int floorNumber) {
    setState(() {
      _activeFloor = floorNumber;
      _nodeToReanchorId = null;
      _isConnecting = false;
      _connectionStartNodeId = null;
      _status = 'Surveying Floor $floorNumber.';
    });
    unawaited(_restoreSurveyMarkers());
  }

  Future<void> _chooseFloor() async {
    final floorNumber = await showCupertinoModalPopup<int>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Choose floor'),
        actions: _floors
            .map(
              (floor) => CupertinoActionSheetAction(
                isDefaultAction: floor.number == _activeFloor,
                onPressed: () => Navigator.pop(context, floor.number),
                child: Text(floor.name),
              ),
            )
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
    if (floorNumber != null && mounted) _selectFloor(floorNumber);
  }

  Future<void> _addNextFloor() async {
    final floorNumber = _floors.isEmpty
        ? 5
        : _floors.map((floor) => floor.number).reduce((a, b) => a > b ? a : b) +
              1;
    final floor = SurveyFloor(number: floorNumber, name: 'Floor $floorNumber');
    setState(() {
      _resetRouteGuidance();
      _nodeToReanchorId = null;
      _floors.add(floor);
      _activeFloor = floorNumber;
      _isConnecting = false;
      _connectionStartNodeId = null;
      _routeStartNodeId = null;
      _routeDestinationNodeId = null;
      _activeRoute = null;
      _routeMessage = null;
      _status = 'Floor $floorNumber added. Move your iPhone to scan the floor.';
    });
    unawaited(_restoreSurveyMarkers());
    try {
      await _repository.upsertFloor(floor);
    } catch (error) {
      debugPrint('ARCIS floor save failed: $error');
      if (mounted) {
        setState(
          () => _status =
              'Floor $floorNumber is active, but floor sync failed. Apply the updated Supabase schema.',
        );
      }
    }
  }

  Future<void> _deleteActiveFloor() async {
    if (_isLoadingSurvey) return;
    if (_floors.length <= 1) {
      setState(() => _status = 'A survey must keep at least one floor.');
      return;
    }
    if (_placedNodes.any((placed) => placed.node.floor == _activeFloor)) {
      setState(
        () => _status =
            'Floor $_activeFloor has nodes. Delete its nodes before deleting the floor.',
      );
      return;
    }

    final floorNumber = _activeFloor;
    final confirmed = defaultTargetPlatform == TargetPlatform.iOS
        ? await showCupertinoDialog<bool>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: Text('Delete Floor $floorNumber?'),
              content: const Text(
                'This empty floor will be removed from this survey.',
              ),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete floor'),
                ),
              ],
            ),
          )
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('Delete Floor $floorNumber?'),
              content: const Text(
                'This empty floor will be removed from this survey.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Delete floor'),
                ),
              ],
            ),
          );
    if (confirmed != true || !mounted) return;

    try {
      await _repository.deleteFloor(floorNumber);
    } catch (error) {
      debugPrint('ARCIS floor delete failed: $error');
      if (mounted) {
        setState(
          () => _status =
              'Floor could not be deleted. Check its nodes and the Supabase floor schema.',
        );
      }
      return;
    }
    if (!mounted) return;

    final remainingFloors = _floors
        .where((floor) => floor.number != floorNumber)
        .toList();
    final fallbackFloor =
        remainingFloors
            .where((floor) => floor.number < floorNumber)
            .lastOrNull ??
        remainingFloors.first;
    setState(() {
      _resetRouteGuidance();
      _floors.removeWhere((floor) => floor.number == floorNumber);
      _activeFloor = fallbackFloor.number;
      _routeStartNodeId = null;
      _routeDestinationNodeId = null;
      _activeRoute = null;
      _routeMessage = null;
      _status = 'Floor $floorNumber deleted. Surveying ${fallbackFloor.name}.';
    });
    unawaited(_restoreSurveyMarkers());
  }

  @override
  Widget build(BuildContext context) {
    final canUseAr =
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android;
    final floorNodes = _placedNodes
        .where((placed) => placed.node.floor == _activeFloor)
        .map((placed) => placed.node)
        .toList();
    final floorNodeIds = floorNodes.map((node) => node.id).toSet();
    final floorConnections = _connections
        .where(
          (connection) =>
              floorNodeIds.contains(connection.nodeAId) &&
              floorNodeIds.contains(connection.nodeBId),
        )
        .toList();
    final route = _activeRoute;
    final guidanceTarget = _isGuidingRoute && route != null
        ? route.nodes[_navigationStepIndex
              .clamp(0, route.nodes.length - 1)
              .toInt()]
        : null;
    final unanchoredNodeIds = _placedNodes
        .where(
          (placed) =>
              placed.anchor == null && placed.node.cloudAnchorId == null,
        )
        .map((placed) => placed.node.id)
        .toSet();
    final content = Stack(
      fit: StackFit.expand,
      children: [
        if (canUseAr)
          ARView(
            onARViewCreated: _onArViewCreated,
            planeDetectionConfig: PlaneDetectionConfig.horizontal,
            showPlatformType: true,
            permissionPromptDescription:
                'ARCIS needs camera access to survey the 5th floor.',
          )
        else
          const _UnsupportedPlatformView(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final viewport = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final initialPanel = Size(
                  viewport.width * 0.88,
                  viewport.height * 0.65,
                );
                final panelSize = Size(
                  (_panelSize?.width ?? initialPanel.width)
                      .clamp(math.min(240, viewport.width), viewport.width)
                      .toDouble(),
                  (_panelSize?.height ?? initialPanel.height)
                      .clamp(math.min(180, viewport.height), viewport.height)
                      .toDouble(),
                );
                final defaultTop = math.max(
                  0.0,
                  viewport.height - panelSize.height,
                );
                final panelLeft = (_panelOffset?.dx ?? 0)
                    .clamp(0.0, math.max(0.0, viewport.width - panelSize.width))
                    .toDouble();
                final panelTop = (_panelOffset?.dy ?? defaultTop)
                    .clamp(
                      0.0,
                      math.max(0.0, viewport.height - panelSize.height),
                    )
                    .toDouble();

                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    if (!_isGuidingRoute && !_isRoutePageOpen)
                      Positioned(
                        left: 0,
                        top: 0,
                        width: constraints.maxWidth,
                        child: _Header(
                          floor: _activeFloor,
                          nodeCount: floorNodes.length,
                          canPlanRoute: true,
                          onPlanRoute: () {
                            setState(() => _isRoutePageOpen = true);
                          },
                        ),
                      ),
                    if (_isGuidingRoute &&
                        route != null &&
                        guidanceTarget != null)
                      Positioned.fill(
                        child: RouteGuidanceOverlay(
                          destinationName: route.nodes.last.name,
                          bearingRadians: _guidanceBearingRadians,
                          distanceMeters: _guidanceDistanceMeters,
                          onStop: _stopRouteGuidance,
                        ),
                      )
                    else if (_isRoutePageOpen)
                      Positioned.fill(
                        child: RouteNavigationPage(
                          nodes: _placedNodes
                              .map((placedNode) => placedNode.node)
                              .toList(),
                          surveyId: _activeSurveyId,
                          floorNumbers: _floors
                              .map((floor) => floor.number)
                              .toList(),
                          connections: _connections,
                          route: _activeRoute,
                          startFloor: _routeStartFloor,
                          startNodeId: _routeStartNodeId,
                          destinationNodeId: _routeDestinationNodeId,
                          unanchoredNodeIds: _activeRoute == null
                              ? const {}
                              : {
                                  for (final node in _activeRoute!.nodes)
                                    if (unanchoredNodeIds.contains(node.id))
                                      node.id,
                                },
                          message: _routeMessage,
                          canStartNavigation:
                              _sessionManager != null &&
                              _objectManager != null &&
                              !_isResolvingRouteAnchors &&
                              _canAutoGuideActiveRoute,
                          onStartChanged: _setRouteStart,
                          onStartFloorChanged: _setRouteStartFloor,
                          onDestinationChanged: _setRouteDestination,
                          onFindRoute: _findRoute,
                          onStartNavigation: _startRouteGuidance,
                          onReanchorNode: (nodeId) {
                            final index = _placedNodes.indexWhere(
                              (placedNode) => placedNode.node.id == nodeId,
                            );
                            if (index >= 0) _beginNodeReanchor(index);
                          },
                          onBack: () {
                            setState(() => _isRoutePageOpen = false);
                          },
                          onCopySurveyId: _copySurveyId,
                          onOpenSurveyId: _openSharedSurveyDialog,
                        ),
                      )
                    else
                      Positioned(
                        left: panelLeft,
                        top: panelTop,
                        width: panelSize.width,
                        height: panelSize.height,
                        child: _InstructionPanel(
                          onMove: (delta) =>
                              _movePanel(delta, viewport, panelSize),
                          onResize: (delta) =>
                              _resizePanel(delta, viewport, panelSize),
                          status: _status,
                          isLoading: _isLoadingSurvey,
                          nodes: _placedNodes
                              .map((placed) => placed.node)
                              .toList(),
                          unanchoredNodeIds: unanchoredNodeIds,
                          floors: _floors,
                          activeFloor: _activeFloor,
                          floorNodes: floorNodes,
                          floorConnections: floorConnections,
                          connections: _connections,
                          routeStartNodeId: _routeStartNodeId,
                          routeDestinationNodeId: _routeDestinationNodeId,
                          activeRoute: _activeRoute,
                          isGuidingRoute: _isGuidingRoute,
                          navigationStepIndex: _navigationStepIndex,
                          isConnecting: _isConnecting,
                          connectingFromNodeId: _connectionStartNodeId,
                          onRemove: _removeLastNode,
                          onEdit: _editNode,
                          onConnect: _connectNode,
                          onReanchorNode: _beginNodeReanchor,
                          onToggleConnecting: _toggleConnecting,
                          onRemoveConnection: _removeConnection,
                          onFloorChanged: _selectFloor,
                          onChooseFloor: _chooseFloor,
                          onAddFloor: _addNextFloor,
                          onDeleteFloor: _deleteActiveFloor,
                          onExport: _exportSurvey,
                          onClear: _clearSurvey,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoTheme(
        data: const CupertinoThemeData(
          brightness: Brightness.dark,
          primaryColor: Color(0xFF67E8F9),
          scaffoldBackgroundColor: Color(0xFF071014),
        ),
        child: Builder(
          builder: (context) => DefaultTextStyle(
            style: CupertinoTheme.of(context).textTheme.textStyle,
            child: Scaffold(
              backgroundColor: const Color(0xFF071014),
              body: content,
            ),
          ),
        ),
      );
    }
    return Scaffold(backgroundColor: const Color(0xFF071014), body: content);
  }

  void _onArViewCreated(
    ARSessionManager sessionManager,
    ARObjectManager objectManager,
    ARAnchorManager anchorManager,
    ARLocationManager locationManager,
  ) {
    _sessionManager = sessionManager;
    _objectManager = objectManager;
    _anchorManager = anchorManager;
    setState(() => _status = 'Starting camera and plane detection...');

    sessionManager.onInitialize(
      showFeaturePoints: false,
      showPlanes: defaultTargetPlatform != TargetPlatform.iOS,
      showWorldOrigin: false,
    );
    objectManager.onInitialize();
    anchorManager.onAnchorUploaded = _onCloudAnchorUploaded;
    anchorManager.onAnchorUploadFailed = _onCloudAnchorUploadFailed;
    anchorManager.onAnchorDownloaded = _onCloudAnchorDownloaded;
    anchorManager.onAnchorDownloadFailed = _onCloudAnchorDownloadFailed;
    anchorManager.initGoogleCloudAnchorMode();
    sessionManager.onPlaneOrPointTap = _onPlaneTapped;
  }

  Future<void> _onPlaneTapped(List<ARHitTestResult> hitTestResults) async {
    if (_isLoadingSurvey || _isPlacing) return;

    final planeHit = hitTestResults
        .where((result) => result.type == ARHitTestResultType.plane)
        .firstOrNull;
    if (planeHit == null || _anchorManager == null || _objectManager == null) {
      setState(() => _status = 'No horizontal plane found. Keep scanning.');
      return;
    }

    _isPlacing = true;
    final position = planeHit.worldTransform.getTranslation();
    final anchor = ARPlaneAnchor(
      transformation: planeHit.worldTransform,
      name: 'arcis-anchor-${const Uuid().v4()}',
      ttl: 365,
    );
    bool didAddAnchor;
    try {
      didAddAnchor = await _anchorManager!.addAnchor(anchor) ?? false;
    } catch (error) {
      debugPrint('ARCIS anchor placement failed: $error');
      _isPlacing = false;
      if (mounted) {
        setState(() => _status = 'Could not place the anchor. Try again.');
      }
      return;
    }
    if (!didAddAnchor) {
      _isPlacing = false;
      setState(() => _status = 'Could not anchor the marker. Try again.');
      return;
    }

    final nodeToReanchorId = _nodeToReanchorId;
    if (nodeToReanchorId != null) {
      await _reanchorSurveyNode(nodeToReanchorId, position, anchor);
      return;
    }

    final nodeNumber = _nextNodeNumber++;
    final marker = ARNode(
      name: 'survey-marker-$nodeNumber',
      type: NodeType.localGLB,
      uri: _markerAssetUri,
      position: vm.Vector3.zero(),
      scale: vm.Vector3.all(0.02),
    );
    bool didAddMarker;
    try {
      didAddMarker =
          await _objectManager!.addNode(marker, planeAnchor: anchor) ?? false;
    } catch (error) {
      debugPrint('ARCIS marker placement failed: $error');
      await _anchorManager!.removeAnchor(anchor);
      _isPlacing = false;
      if (mounted) {
        setState(() => _status = 'Could not load the marker. Try again.');
      }
      return;
    }
    if (!didAddMarker) {
      await _anchorManager!.removeAnchor(anchor);
      _isPlacing = false;
      setState(() => _status = 'Could not place the 3D marker. Try again.');
      return;
    }

    final surveyNode = SurveyNode(
      id: 'node-$nodeNumber',
      name: 'Survey node $nodeNumber',
      type: SurveyNodeType.corridor,
      floor: _activeFloor,
      worldPosition: position,
    );
    _placedNodes.add(
      _PlacedSurveyNode(node: surveyNode, marker: marker, anchor: anchor),
    );
    await _persistNode(surveyNode);
    _isPlacing = false;
    if (!mounted) return;
    setState(
      () =>
          _status = 'Node $nodeNumber placed. Tap another surface to continue.',
    );
    unawaited(_uploadCloudAnchor(anchor, surveyNode.id));
    debugPrint(
      'ARCIS node-$nodeNumber position: X=${position.x}, Y=${position.y}, Z=${position.z}',
    );
  }

  void _beginNodeReanchor(int index) {
    if (index < 0 || index >= _placedNodes.length) return;
    final node = _placedNodes[index].node;
    setState(() {
      _isRoutePageOpen = false;
      _activeFloor = node.floor;
      _nodeToReanchorId = node.id;
      _status = 'Tap a detected surface to anchor ${node.name}.';
    });
    unawaited(_restoreSurveyMarkers());
  }

  Future<void> _reanchorSurveyNode(
    String nodeId,
    vm.Vector3 position,
    ARPlaneAnchor anchor,
  ) async {
    final index = _placedNodes.indexWhere(
      (placedNode) => placedNode.node.id == nodeId,
    );
    final objectManager = _objectManager;
    if (index < 0 || objectManager == null) {
      await _anchorManager?.removeAnchor(anchor);
      if (mounted) {
        setState(() {
          _nodeToReanchorId = null;
          _isPlacing = false;
          _status = 'That saved waypoint is no longer available.';
        });
      }
      return;
    }

    final placedNode = _placedNodes[index];
    final updatedNode = SurveyNode(
      id: placedNode.node.id,
      name: placedNode.node.name,
      type: placedNode.node.type,
      floor: placedNode.node.floor,
      worldPosition: position,
    );
    final marker = ARNode(
      name: 'survey-marker-${updatedNode.id}-reanchored-${const Uuid().v4()}',
      type: NodeType.localGLB,
      uri: _markerAssetUri,
      position: vm.Vector3.zero(),
      scale: vm.Vector3.all(0.02),
    );
    try {
      final didAddMarker =
          await objectManager.addNode(marker, planeAnchor: anchor) ?? false;
      if (!didAddMarker) {
        throw StateError('AR scene rejected the saved waypoint marker.');
      }
    } catch (error) {
      debugPrint('ARCIS saved waypoint re-anchor failed: $error');
      await _anchorManager?.removeAnchor(anchor);
      _isPlacing = false;
      if (mounted) {
        setState(
          () => _status = 'Could not anchor ${updatedNode.name}. Try again.',
        );
      }
      return;
    }

    if (placedNode.marker != null) {
      await objectManager.removeNode(placedNode.marker!);
    }
    if (placedNode.anchor != null) {
      await _anchorManager?.removeAnchor(placedNode.anchor!);
    }
    _placedNodes[index] = placedNode.copyWith(
      node: updatedNode,
      marker: marker,
      anchor: anchor,
    );
    _isPlacing = false;
    if (!mounted) return;
    setState(() {
      _nodeToReanchorId = null;
      _activeRoute = null;
      _routeMessage = null;
      _status = '${updatedNode.name} anchored. Continue anchoring waypoints.';
    });
    await _persistNode(updatedNode);
    unawaited(_uploadCloudAnchor(anchor, updatedNode.id));
  }

  Future<void> _removeLastNode() async {
    if (_placedNodes.isEmpty) return;
    final placedNode = _placedNodes.removeLast();
    final marker = placedNode.marker;
    final anchor = placedNode.anchor;
    _connections.removeWhere(
      (connection) =>
          connection.nodeAId == placedNode.node.id ||
          connection.nodeBId == placedNode.node.id,
    );
    if (_connectionStartNodeId == placedNode.node.id) {
      _connectionStartNodeId = null;
    }
    if (marker != null) await _objectManager?.removeNode(marker);
    if (anchor != null) await _anchorManager?.removeAnchor(anchor);
    await _deleteNode(placedNode.node.id);
    if (!mounted) return;
    if (_placedNodes.isEmpty) {
      _nextNodeNumber = 1;
    }
    setState(() {
      _resetRouteGuidance();
      _nodeToReanchorId = null;
      _status = _placedNodes.isEmpty
          ? 'Node removed. Tap a detected plane to place another.'
          : 'Node removed. Tap another surface to continue.';
      _routeStartNodeId = _routeStartNodeId == placedNode.node.id
          ? null
          : _routeStartNodeId;
      _routeDestinationNodeId = _routeDestinationNodeId == placedNode.node.id
          ? null
          : _routeDestinationNodeId;
      _activeRoute = null;
      _routeMessage = null;
    });
  }

  Future<void> _editNode(int index) async {
    if (index < 0 || index >= _placedNodes.length) return;
    final placedNode = _placedNodes[index];
    final updatedNode = defaultTargetPlatform == TargetPlatform.iOS
        ? await showCupertinoDialog<SurveyNode>(
            context: context,
            builder: (context) => _EditSurveyNodeDialog(node: placedNode.node),
          )
        : await showDialog<SurveyNode>(
            context: context,
            builder: (context) => _EditSurveyNodeDialog(node: placedNode.node),
          );
    if (!mounted || updatedNode == null) return;
    setState(() {
      _resetRouteGuidance();
      _placedNodes[index] = placedNode.copyWith(node: updatedNode);
      _activeRoute = null;
    });
    await _persistNode(updatedNode);
  }

  Future<bool> _persistNode(SurveyNode node) async {
    try {
      await _repository.upsertNode(node);
      return true;
    } catch (error) {
      debugPrint('ARCIS Supabase upsert failed: $error');
      if (mounted) {
        setState(() => _status = 'Node saved locally; database sync failed.');
      }
      return false;
    }
  }

  Future<void> _uploadCloudAnchor(ARPlaneAnchor anchor, String nodeId) async {
    final anchorManager = _anchorManager;
    if (anchorManager == null) {
      if (mounted) {
        setState(
          () => _status =
              'Waypoint saved, but AR Cloud Anchor service is not ready. Re-anchor it to retry.',
        );
      }
      return;
    }
    final anchorName = anchor.name;
    _cloudAnchorUploadNodeIds[anchorName] = nodeId;
    _cloudAnchorUploadTimers.remove(anchorName)?.cancel();
    _cloudAnchorUploadTimers[anchorName] = Timer(const Duration(seconds: 90), () {
      _cloudAnchorUploadTimers.remove(anchorName);
      debugPrint(
        'ARCIS Cloud Anchor upload timed out for $nodeId ($anchorName).',
      );
      if (!mounted) return;
      setState(
        () => _status =
            'Cloud Anchor upload for ${_nodeName(nodeId)} is taking longer than expected. Waiting for the host result.',
      );
    });
    if (mounted) {
      setState(
        () => _status = 'Uploading ${_nodeName(nodeId)} to Cloud Anchors...',
      );
    }
    try {
      final uploaded = await anchorManager.uploadAnchor(anchor) ?? false;
      if (!uploaded) {
        _cloudAnchorUploadTimers.remove(anchorName)?.cancel();
        _cloudAnchorUploadNodeIds.remove(anchorName);
        if (!mounted) return;
        setState(
          () => _status =
              'Cloud Anchor upload could not start for $nodeId. Check Cloud Anchor setup and re-anchor to retry.',
        );
      }
    } catch (error) {
      _cloudAnchorUploadTimers.remove(anchorName)?.cancel();
      _cloudAnchorUploadNodeIds.remove(anchorName);
      debugPrint('ARCIS cloud anchor upload failed for $nodeId: $error');
      if (mounted) {
        setState(
          () => _status =
              'Cloud Anchor upload failed for $nodeId. Check the device log, then re-anchor to retry.',
        );
      }
    }
  }

  void _onCloudAnchorUploaded(ARAnchor uploadedAnchor) {
    if (uploadedAnchor is! ARPlaneAnchor) return;
    unawaited(_saveUploadedCloudAnchor(uploadedAnchor));
  }

  void _onCloudAnchorUploadFailed(String anchorName, String message) {
    _cloudAnchorUploadTimers.remove(anchorName)?.cancel();
    final nodeId = _cloudAnchorUploadNodeIds.remove(anchorName);
    if (nodeId == null) {
      debugPrint(
        'ARCIS received Cloud Anchor upload failure for untracked anchor '
        '$anchorName: $message',
      );
      return;
    }
    debugPrint('ARCIS Cloud Anchor upload failed for $nodeId: $message');
    if (!mounted) return;

    final isFeatureMapFailure = message.contains('feature map insufficient');
    setState(
      () => _status = isFeatureMapFailure
          ? 'Could not share ${_nodeName(nodeId)}: not enough visual detail '
                'around the anchor. Slowly scan a textured area from multiple '
                'angles, then re-anchor to retry.'
          : 'Could not share ${_nodeName(nodeId)}: $message Re-anchor to retry.',
    );
  }

  Future<void> _saveUploadedCloudAnchor(ARPlaneAnchor uploadedAnchor) async {
    final anchorName = uploadedAnchor.name;
    _cloudAnchorUploadTimers.remove(anchorName)?.cancel();
    final nodeId = _cloudAnchorUploadNodeIds.remove(anchorName);
    if (nodeId == null) {
      debugPrint(
        'ARCIS received Cloud Anchor callback for an untracked anchor $anchorName.',
      );
      return;
    }
    final cloudAnchorId = uploadedAnchor.cloudanchorid;
    final index = _placedNodes.indexWhere(
      (placedNode) => placedNode.node.id == nodeId,
    );
    if (index < 0 || cloudAnchorId == null || cloudAnchorId.isEmpty) {
      debugPrint(
        'ARCIS received an invalid Cloud Anchor callback for $nodeId.',
      );
      if (mounted) {
        setState(
          () => _status =
              'Cloud Anchor hosting returned no ID for $nodeId. Check the iPhone logs and retry anchoring.',
        );
      }
      return;
    }
    if (!identical(_placedNodes[index].anchor, uploadedAnchor)) {
      final currentAnchorName = _placedNodes[index].anchor?.name;
      debugPrint(
        'ARCIS ignored stale Cloud Anchor callback for $nodeId: '
        'callback=$anchorName, current=$currentAnchorName.',
      );
      if (mounted) {
        setState(
          () => _status =
              'An earlier anchor upload for ${_nodeName(nodeId)} finished, '
              'but that anchor has since changed. The current anchor must finish uploading before it can be saved.',
        );
      }
      return;
    }

    final updatedNode = _placedNodes[index].node.copyWith(
      cloudAnchorId: cloudAnchorId,
    );
    _placedNodes[index] = _placedNodes[index].copyWith(node: updatedNode);
    final didPersist = await _persistNode(updatedNode);
    if (mounted) {
      setState(
        () => _status = didPersist
            ? 'Saved ${updatedNode.name} for future AR sessions.'
            : 'Cloud Anchor created for ${updatedNode.name}, but its ID could not be saved to the database.',
      );
    }
  }

  String _nodeName(String nodeId) {
    return _placedNodes
            .where((placedNode) => placedNode.node.id == nodeId)
            .firstOrNull
            ?.node
            .name ??
        nodeId;
  }

  ARAnchor _onCloudAnchorDownloaded(Map<String, dynamic> serializedAnchor) {
    final cloudAnchorId = serializedAnchor['cloudanchorid'] as String?;
    final pending = cloudAnchorId == null
        ? null
        : _pendingCloudAnchorResolutions[cloudAnchorId];
    debugPrint(
      'ARCIS received resolved Cloud Anchor callback: '
      'id=$cloudAnchorId, pending=${pending != null}',
    );
    final anchorJson = Map<String, dynamic>.from(serializedAnchor)
      ..['name'] =
          pending?.node.id ??
          serializedAnchor['name']?.toString() ??
          'unmatched-cloud-anchor-${const Uuid().v4()}';
    final anchor = ARPlaneAnchor.fromJson(anchorJson);
    if (pending == null) return anchor;
    unawaited(_attachResolvedCloudAnchor(pending, anchor));
    return anchor;
  }

  void _onCloudAnchorDownloadFailed(String cloudAnchorId, String message) {
    final pending = _pendingCloudAnchorResolutions[cloudAnchorId];
    debugPrint(
      'ARCIS Cloud Anchor failure callback: '
      'id=$cloudAnchorId, pending=${pending != null}, message=$message',
    );
    if (pending == null || pending.completer.isCompleted) return;
    pending.completer.completeError(
      StateError('Could not resolve ${pending.node.name}: $message'),
    );
  }

  Future<void> _attachResolvedCloudAnchor(
    _PendingCloudAnchorResolution pending,
    ARPlaneAnchor anchor,
  ) async {
    final objectManager = _objectManager;
    final index = _placedNodes.indexWhere(
      (placedNode) => placedNode.node.id == pending.node.id,
    );
    if (objectManager == null || index < 0) {
      pending.completer.completeError(
        StateError('Saved waypoint ${pending.node.name} is unavailable.'),
      );
      return;
    }

    final currentNode = _placedNodes[index].node;
    final localizedNode = SurveyNode(
      id: currentNode.id,
      name: currentNode.name,
      type: currentNode.type,
      floor: currentNode.floor,
      worldPosition: anchor.transformation.getTranslation(),
      cloudAnchorId: currentNode.cloudAnchorId,
    );
    debugPrint(
      'ARCIS attached resolved Cloud Anchor to ${currentNode.name} '
      '(${currentNode.cloudAnchorId}).',
    );
    final showMarker =
        !_isResolvingRouteAnchors ||
        _activeRoute?.nodes.last.id == localizedNode.id;
    final marker = showMarker ? _createSurveyMarker(localizedNode) : null;
    try {
      if (marker != null) {
        final didAdd =
            await objectManager.addNode(marker, planeAnchor: anchor) ?? false;
        if (!didAdd) {
          throw StateError(
            'AR scene rejected the resolved anchor for ${currentNode.name}.',
          );
        }
      }
      _placedNodes[index] = _placedNodes[index].copyWith(
        node: localizedNode,
        anchor: anchor,
        marker: marker,
        clearMarker: marker == null,
      );
      if (!pending.completer.isCompleted) {
        pending.completer.complete(anchor);
      }
    } catch (error, stackTrace) {
      debugPrint('ARCIS cloud anchor restore failed: $error');
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error, stackTrace);
      }
    }
  }

  Future<void> _deleteNode(String nodeId) async {
    try {
      await _repository.deleteNode(nodeId);
    } catch (error) {
      debugPrint('ARCIS Supabase delete failed: $error');
      if (mounted) {
        setState(() => _status = 'Node removed locally; database sync failed.');
      }
    }
  }

  Future<void> _exportSurvey() async {
    final payload = {
      'activeFloor': _activeFloor,
      'floors': _floors
          .map((floor) => {'number': floor.number, 'name': floor.name})
          .toList(),
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'nodes': _placedNodes.map((placed) => placed.node.toJson()).toList(),
      'connections': _connections
          .map((connection) => connection.toJson())
          .toList(),
    };
    final json = const JsonEncoder.withIndent('  ').convert(payload);
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Survey JSON'),
          content: SizedBox(
            height: 300,
            child: SingleChildScrollView(child: SelectableText(json)),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Survey JSON'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(child: SelectableText(json)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }
  }

  void _toggleConnecting() {
    setState(() {
      _isConnecting = !_isConnecting;
      _connectionStartNodeId = null;
      _status = _isConnecting
          ? 'Choose a start node, then choose the node it connects to.'
          : 'Connection mode closed.';
    });
  }

  Future<void> _connectNode(int index) async {
    if (!_isConnecting || index < 0 || index >= _placedNodes.length) return;
    final selectedNode = _placedNodes[index].node;
    final firstNodeId = _connectionStartNodeId;
    if (firstNodeId == null) {
      setState(() {
        _connectionStartNodeId = selectedNode.id;
        _status =
            'Now choose a second node to connect to ${selectedNode.name}.';
      });
      return;
    }
    if (firstNodeId == selectedNode.id) {
      setState(() => _status = 'Choose a different node for the connection.');
      return;
    }
    if (_connections.any(
      (connection) => connection.connects(firstNodeId, selectedNode.id),
    )) {
      setState(() {
        _connectionStartNodeId = null;
        _status = 'Those nodes are already connected.';
      });
      return;
    }

    final firstNode = _placedNodes
        .where((placedNode) => placedNode.node.id == firstNodeId)
        .firstOrNull
        ?.node;
    if (firstNode == null) {
      setState(() {
        _connectionStartNodeId = null;
        _status = 'The selected start node no longer exists.';
      });
      return;
    }
    var connectionType = SurveyConnectionType.corridor;
    if (firstNode.floor != selectedNode.floor) {
      final selectedType = await _chooseVerticalConnectionType(
        firstNode,
        selectedNode,
      );
      if (selectedType == null || !mounted) return;
      connectionType = selectedType;
    }

    final endpointIds = [firstNodeId, selectedNode.id]..sort();
    final connection = SurveyConnection(
      id: const Uuid().v4(),
      nodeAId: endpointIds.first,
      nodeBId: endpointIds.last,
      type: connectionType,
    );
    setState(() {
      _connections.add(connection);
      _connectionStartNodeId = null;
      _resetRouteGuidance();
      _activeRoute = null;
      _routeMessage = null;
      _status = connectionType == SurveyConnectionType.corridor
          ? 'Corridor connection added.'
          : '${_connectionTypeLabel(connectionType)} connection added between Floors ${firstNode.floor} and ${selectedNode.floor}.';
    });
    try {
      await _repository.upsertConnection(connection);
    } catch (error) {
      debugPrint('ARCIS connection save failed: $error');
      if (mounted) {
        setState(
          () => _status = 'Connection added for this session; sync failed.',
        );
      }
    }
  }

  Future<SurveyConnectionType?> _chooseVerticalConnectionType(
    SurveyNode firstNode,
    SurveyNode secondNode,
  ) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return showCupertinoModalPopup<SurveyConnectionType>(
        context: context,
        builder: (context) => CupertinoActionSheet(
          title: Text(
            'Connect Floor ${firstNode.floor} to Floor ${secondNode.floor}',
          ),
          actions: SurveyConnectionType.values
              .where((type) => type != SurveyConnectionType.corridor)
              .map(
                (type) => CupertinoActionSheetAction(
                  onPressed: () => Navigator.pop(context, type),
                  child: Text(_connectionTypeLabel(type)),
                ),
              )
              .toList(),
          cancelButton: CupertinoActionSheetAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ),
      );
    }
    return showDialog<SurveyConnectionType>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          'Connect Floor ${firstNode.floor} to Floor ${secondNode.floor}',
        ),
        children: SurveyConnectionType.values
            .where((type) => type != SurveyConnectionType.corridor)
            .map(
              (type) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, type),
                child: Text(_connectionTypeLabel(type)),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _removeConnection(SurveyConnection connection) async {
    setState(() {
      _connections.remove(connection);
      _resetRouteGuidance();
      _activeRoute = null;
      _routeMessage = null;
    });
    try {
      await _repository.deleteConnection(connection.id);
    } catch (error) {
      debugPrint('ARCIS connection delete failed: $error');
      if (mounted) {
        setState(
          () => _status = 'Connection removed for this session; sync failed.',
        );
      }
    }
  }

  void _setRouteStart(String? nodeId) {
    setState(() {
      _resetRouteGuidance();
      _routeStartNodeId = nodeId;
      _activeRoute = null;
      _routeMessage = null;
    });
  }

  void _setRouteStartFloor(int? floor) {
    if (floor == null || floor == _routeStartFloor) return;
    setState(() {
      _resetRouteGuidance();
      _routeStartFloor = floor;
      _activeFloor = floor;
      _routeStartNodeId = null;
      _activeRoute = null;
      _routeMessage = null;
    });
    unawaited(_restoreSurveyMarkers());
  }

  void _setRouteDestination(String? nodeId) {
    setState(() {
      _resetRouteGuidance();
      _routeDestinationNodeId = nodeId;
      _activeRoute = null;
      _routeMessage = null;
    });
  }

  Future<void> _copySurveyId() async {
    if (_activeSurveyId.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _activeSurveyId));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Survey ID copied. Share it with the other device.'),
      ),
    );
  }

  Future<void> _openSharedSurveyDialog() async {
    final sharedSurveyId = await showDialog<String>(
      context: context,
      builder: (context) => const _SharedSurveyIdDialog(),
    );
    if (sharedSurveyId == null || !mounted) return;
    await _switchSurvey(sharedSurveyId);
  }

  Future<void> _switchSurvey(String value) async {
    final surveyId = value.trim().toLowerCase();
    final uuidPattern = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
    );
    if (!uuidPattern.hasMatch(surveyId)) {
      setState(() => _routeMessage = 'Enter a valid survey ID.');
      return;
    }

    _guidanceTimer?.cancel();
    _isGuidingRoute = false;
    _isAutoGuidingRoute = false;
    _guidanceBearingRadians = null;
    _guidanceDistanceMeters = null;
    for (final placedNode in _placedNodes) {
      if (placedNode.marker != null) {
        await _objectManager?.removeNode(placedNode.marker!);
      }
      if (placedNode.anchor != null) {
        await _anchorManager?.removeAnchor(placedNode.anchor!);
      }
    }
    if (!mounted) return;
    setState(() {
      _isLoadingSurvey = true;
      _activeRoute = null;
      _routeStartNodeId = null;
      _routeDestinationNodeId = null;
      _routeMessage = null;
      _placedNodes.clear();
      _connections.clear();
      _floors.clear();
      _activeFloor = 5;
      _nextNodeNumber = 1;
      _status = 'Loading shared survey...';
    });
    await _initializeSurvey(requestedSurveyId: surveyId);
  }

  void _findRoute() {
    final startNodeId = _routeStartNodeId;
    final destinationNodeId = _routeDestinationNodeId;
    if (startNodeId == null || destinationNodeId == null) {
      setState(() => _routeMessage = 'Choose a start and destination.');
      return;
    }

    final route = calculateShortestSurveyRoute(
      nodes: _placedNodes.map((placedNode) => placedNode.node).toList(),
      connections: _connections,
      startNodeId: startNodeId,
      destinationNodeId: destinationNodeId,
    );
    _guidanceTimer?.cancel();
    unawaited(_restoreSurveyMarkers());
    setState(() {
      _activeRoute = route;
      _isGuidingRoute = false;
      _isAutoGuidingRoute = false;
      _navigationStepIndex = 0;
      _routeMessage = route == null
          ? 'No connected route between these nodes.'
          : null;
    });
  }

  Future<void> _startRouteGuidance() async {
    final route = _activeRoute;
    if (route == null || _isResolvingRouteAnchors) return;
    if (!_canAutoGuideActiveRoute) return;
    setState(() {
      _isResolvingRouteAnchors = true;
      _routeMessage = 'Locating saved waypoints in this AR session...';
    });

    try {
      final localizedRoute = await _resolveRouteAnchors(route);
      if (!mounted) return;
      _guidanceTimer?.cancel();
      setState(() {
        _activeRoute = localizedRoute;
        _isGuidingRoute = true;
        _isAutoGuidingRoute = true;
        _navigationStepIndex = 0;
        _activeFloor = localizedRoute.nodes.first.floor;
        _guidanceBearingRadians = null;
        _guidanceDistanceMeters = null;
        _routeMessage = null;
        _status =
            'Following live AR position to ${localizedRoute.nodes.first.name}.';
        _isRoutePageOpen = false;
      });
      await _showOnlyGuidanceDestinationMarker(localizedRoute.nodes.last);
      _guidanceTimer = Timer.periodic(
        const Duration(milliseconds: 300),
        (_) => unawaited(_checkGuidancePosition()),
      );
    } catch (error) {
      debugPrint('ARCIS route anchor localization failed: $error');
      if (mounted) {
        final routeMessage = error is TimeoutException
            ? 'Could not localize a saved waypoint within 60 seconds. Stand near its original location, scan the surrounding area slowly, and verify internet access before retrying.'
            : error is StateError
            ? error.message.toString()
            : 'Could not localize the saved waypoint: $error';
        setState(() {
          _routeMessage = routeMessage;
          _status = routeMessage;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isResolvingRouteAnchors = false);
      }
    }
  }

  Future<SurveyRoute> _resolveRouteAnchors(SurveyRoute route) async {
    final anchorManager = _anchorManager;
    if (anchorManager == null) {
      throw StateError('The AR anchor manager is not ready.');
    }
    final nodesToResolve = route.nodes.where((node) {
      return !_placedNodes.any(
        (placedNode) =>
            placedNode.node.id == node.id && placedNode.anchor != null,
      );
    }).toList();
    if (nodesToResolve.isEmpty) return route;

    final pendingResolutions = <_PendingCloudAnchorResolution>[];
    for (final node in nodesToResolve) {
      final cloudAnchorId = node.cloudAnchorId;
      if (cloudAnchorId == null || cloudAnchorId.isEmpty) {
        throw StateError('${node.name} has no saved Cloud Anchor.');
      }
      if (_pendingCloudAnchorResolutions.containsKey(cloudAnchorId)) {
        throw StateError('A Cloud Anchor is already being resolved.');
      }
      final pending = _PendingCloudAnchorResolution(
        node: node,
        completer: Completer<ARPlaneAnchor>(),
      );
      _pendingCloudAnchorResolutions[cloudAnchorId] = pending;
      pendingResolutions.add(pending);
    }

    try {
      for (final pending in pendingResolutions) {
        debugPrint(
          'ARCIS requesting Cloud Anchor resolution for '
          '${pending.node.name} (${pending.node.cloudAnchorId}).',
        );
        final didStart = await anchorManager.downloadAnchor(
          pending.node.cloudAnchorId!,
        );
        debugPrint(
          'ARCIS Cloud Anchor resolution request accepted for '
          '${pending.node.name}: $didStart.',
        );
        if (didStart != true) {
          throw StateError('Could not start resolving ${pending.node.name}.');
        }
        try {
          await pending.completer.future.timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw TimeoutException(
              'Could not localize ${pending.node.name}.',
            ),
          );
        } on TimeoutException {
          debugPrint(
            'ARCIS Cloud Anchor resolution timed out for '
            '${pending.node.name} (${pending.node.cloudAnchorId}); '
            'no native success or failure callback was received in 60 seconds.',
          );
          rethrow;
        }
      }
    } finally {
      for (final pending in pendingResolutions) {
        final cloudAnchorId = pending.node.cloudAnchorId;
        if (cloudAnchorId != null &&
            identical(_pendingCloudAnchorResolutions[cloudAnchorId], pending)) {
          _pendingCloudAnchorResolutions.remove(cloudAnchorId);
        }
      }
    }

    final localizedRoute = calculateShortestSurveyRoute(
      nodes: _placedNodes.map((placedNode) => placedNode.node).toList(),
      connections: _connections,
      startNodeId: route.nodes.first.id,
      destinationNodeId: route.nodes.last.id,
    );
    if (localizedRoute == null) {
      throw StateError('The selected route is no longer available.');
    }
    return localizedRoute;
  }

  Future<void> _checkGuidancePosition() async {
    if (_isCheckingGuidancePosition || !_isGuidingRoute) return;
    final route = _activeRoute;
    final sessionManager = _sessionManager;
    if (route == null || sessionManager == null || route.nodes.isEmpty) {
      _guidanceTimer?.cancel();
      return;
    }

    _isCheckingGuidancePosition = true;
    try {
      final cameraPose = await sessionManager.getCameraPose();
      if (!mounted || !_isGuidingRoute) return;
      if (cameraPose == null) {
        if (_guidanceBearingRadians != null ||
            _guidanceDistanceMeters != null) {
          setState(() {
            _guidanceBearingRadians = null;
            _guidanceDistanceMeters = null;
          });
        }
        return;
      }
      final targetIndex = _navigationStepIndex
          .clamp(0, route.nodes.length - 1)
          .toInt();
      final targetNode = route.nodes[targetIndex];
      final targetHasLiveAnchor = _placedNodes.any(
        (placedNode) =>
            placedNode.node.id == targetNode.id && placedNode.anchor != null,
      );
      if (!targetHasLiveAnchor || targetNode.floor != _activeFloor) {
        if (_guidanceBearingRadians != null ||
            _guidanceDistanceMeters != null) {
          setState(() {
            _guidanceBearingRadians = null;
            _guidanceDistanceMeters = null;
          });
        }
        return;
      }
      final bearing = RouteGuidanceOverlay.bearingTo(
        cameraPose: cameraPose,
        targetPosition: targetNode.worldPosition,
      );
      final distance = RouteGuidanceOverlay.distanceTo(
        cameraPose: cameraPose,
        targetPosition: targetNode.worldPosition,
      );
      if (!mounted || !_isGuidingRoute) return;
      if (!distance.isFinite) return;
      setState(() {
        _guidanceBearingRadians = bearing;
        _guidanceDistanceMeters = distance;
      });
      if (_isAutoGuidingRoute && distance <= 0.9) {
        _advanceGuidanceToNextWaypoint(route);
      }
    } finally {
      _isCheckingGuidancePosition = false;
    }
  }

  void _advanceGuidanceToNextWaypoint(SurveyRoute route) {
    if (!_isGuidingRoute) return;
    if (_navigationStepIndex + 1 >= route.nodes.length) {
      _guidanceTimer?.cancel();
      setState(() {
        _isGuidingRoute = false;
        _isAutoGuidingRoute = false;
        _guidanceBearingRadians = null;
        _guidanceDistanceMeters = null;
        _status = 'You have arrived at ${route.nodes.last.name}.';
      });
      unawaited(_restoreSurveyMarkers());
      return;
    }
    setState(() {
      _navigationStepIndex++;
      _setGuidanceFloor(route);
      _guidanceBearingRadians = null;
      _guidanceDistanceMeters = null;
      _status =
          'Following live AR position to ${route.nodes[_navigationStepIndex].name}.';
    });
  }

  void _setGuidanceFloor(SurveyRoute route) {
    final targetIndex = _navigationStepIndex
        .clamp(0, route.nodes.length - 1)
        .toInt();
    _activeFloor = route.nodes[targetIndex].floor;
  }

  Future<void> _showOnlyGuidanceDestinationMarker(SurveyNode targetNode) async {
    final objectManager = _objectManager;
    if (objectManager == null) return;
    final route = _activeRoute;
    if (!_isGuidingRoute ||
        route == null ||
        route.nodes.last.id != targetNode.id) {
      return;
    }

    for (var index = 0; index < _placedNodes.length; index++) {
      final placedNode = _placedNodes[index];
      if (placedNode.node.id != targetNode.id && placedNode.marker != null) {
        await objectManager.removeNode(placedNode.marker!);
        _placedNodes[index] = placedNode.copyWith(clearMarker: true);
      }
    }

    final targetIndex = _placedNodes.indexWhere(
      (placedNode) => placedNode.node.id == targetNode.id,
    );
    if (targetIndex < 0) return;
    final target = _placedNodes[targetIndex];
    final anchor = target.anchor;
    if (anchor == null) return;

    final marker = target.marker ?? _createSurveyMarker(targetNode);
    marker.scale = vm.Vector3.all(0.12);
    if (target.marker == null) {
      try {
        final didAdd =
            await objectManager.addNode(marker, planeAnchor: anchor) ?? false;
        if (!didAdd) {
          throw StateError('AR scene rejected the destination waypoint.');
        }
        _placedNodes[targetIndex] = target.copyWith(marker: marker);
      } catch (error) {
        debugPrint('ARCIS destination waypoint display failed: $error');
        marker.scale = vm.Vector3.all(0.02);
        if (mounted) {
          setState(
            () => _status =
                'The destination waypoint could not be displayed in the camera.',
          );
        }
      }
    }
  }

  ARNode _createSurveyMarker(SurveyNode node) {
    return ARNode(
      name: 'survey-marker-${node.id}-${const Uuid().v4()}',
      type: NodeType.localGLB,
      uri: _markerAssetUri,
      position: vm.Vector3.zero(),
      scale: vm.Vector3.all(0.02),
    );
  }

  Future<void> _restoreSurveyMarkers() async {
    final objectManager = _objectManager;
    if (objectManager == null) return;

    for (var index = 0; index < _placedNodes.length; index++) {
      final placedNode = _placedNodes[index];
      final isGuidanceDestination =
          _isGuidingRoute && _activeRoute?.nodes.last.id == placedNode.node.id;
      final shouldShowMarker = _isGuidingRoute
          ? isGuidanceDestination
          : placedNode.node.floor == _activeFloor;
      final existingMarker = placedNode.marker;
      if (!shouldShowMarker) {
        if (existingMarker != null) {
          await objectManager.removeNode(existingMarker);
          _placedNodes[index] = placedNode.copyWith(clearMarker: true);
        }
        continue;
      }

      final anchor = placedNode.anchor;
      if (anchor == null) continue;

      if (existingMarker != null) {
        existingMarker.scale = vm.Vector3.all(
          isGuidanceDestination ? 0.12 : 0.02,
        );
        continue;
      }

      final marker = _createSurveyMarker(placedNode.node);
      if (isGuidanceDestination) {
        marker.scale = vm.Vector3.all(0.12);
      }
      try {
        final didAdd =
            await objectManager.addNode(marker, planeAnchor: anchor) ?? false;
        if (!didAdd) {
          throw StateError(
            'AR scene rejected the marker for ${placedNode.node.name}.',
          );
        }
        _placedNodes[index] = placedNode.copyWith(marker: marker);
      } catch (error) {
        debugPrint('ARCIS waypoint marker restore failed: $error');
        if (mounted) {
          setState(
            () => _status =
                'Some survey markers could not be restored after navigation.',
          );
        }
      }
    }
  }

  void _stopRouteGuidance() {
    _guidanceTimer?.cancel();
    setState(() {
      _isGuidingRoute = false;
      _isAutoGuidingRoute = false;
      _navigationStepIndex = 0;
      _guidanceBearingRadians = null;
      _guidanceDistanceMeters = null;
      _status = 'Route guidance stopped.';
    });
    unawaited(_restoreSurveyMarkers());
  }

  Future<void> _clearSurvey() async {
    if (_placedNodes.isEmpty) return;
    final shouldClear = defaultTargetPlatform == TargetPlatform.iOS
        ? await showCupertinoDialog<bool>(
            context: context,
            builder: (context) => CupertinoAlertDialog(
              title: const Text('Clear survey?'),
              content: const Text(
                'Remove all captured nodes from this session?',
              ),
              actions: [
                CupertinoDialogAction(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Clear all'),
                ),
              ],
            ),
          )
        : await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Clear survey?'),
              content: const Text(
                'Remove all captured nodes from this session?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Clear all'),
                ),
              ],
            ),
          );
    if (shouldClear != true) return;
    for (final placedNode in _placedNodes) {
      final marker = placedNode.marker;
      final anchor = placedNode.anchor;
      if (marker != null) await _objectManager?.removeNode(marker);
      if (anchor != null) await _anchorManager?.removeAnchor(anchor);
    }
    try {
      await _repository.clearSurvey();
    } catch (error) {
      debugPrint('ARCIS Supabase clear failed: $error');
    }
    if (!mounted) return;
    setState(() {
      _resetRouteGuidance();
      _isConnecting = false;
      _connectionStartNodeId = null;
      _connections.clear();
      _placedNodes.clear();
      _routeStartNodeId = null;
      _routeDestinationNodeId = null;
      _activeRoute = null;
      _routeMessage = null;
      _nodeToReanchorId = null;
      _nextNodeNumber = 1;
      _status = 'Survey cleared. Tap a detected plane to start again.';
    });
  }
}

class _SharedSurveyIdDialog extends StatefulWidget {
  const _SharedSurveyIdDialog();

  @override
  State<_SharedSurveyIdDialog> createState() => _SharedSurveyIdDialogState();
}

class _SharedSurveyIdDialogState extends State<_SharedSurveyIdDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Open a shared survey'),
      content: TextField(
        key: const ValueKey('shared-survey-id-input'),
        controller: _controller,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Survey ID',
          hintText: 'Paste the ID from the other device',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('submit-shared-survey-id'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Load survey'),
        ),
      ],
    );
  }
}

class _EditSurveyNodeDialog extends StatefulWidget {
  const _EditSurveyNodeDialog({required this.node});

  final SurveyNode node;

  @override
  State<_EditSurveyNodeDialog> createState() => _EditSurveyNodeDialogState();
}

class _EditSurveyNodeDialogState extends State<_EditSurveyNodeDialog> {
  late final TextEditingController _nameController;
  late SurveyNodeType _selectedType;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.node.name);
    _selectedType = widget.node.type;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return CupertinoAlertDialog(
        title: Text('Edit ${widget.node.id}'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CupertinoTextField(
                controller: _nameController,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                placeholder: 'Node name',
              ),
              const SizedBox(height: 8),
              CupertinoButton(
                padding: const EdgeInsets.symmetric(vertical: 8),
                onPressed: _showTypePicker,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Node type'),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_nodeTypeLabel(_selectedType)),
                        const SizedBox(width: 4),
                        const Icon(CupertinoIcons.chevron_down, size: 14),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      );
    }
    return AlertDialog(
      title: Text('Edit ${widget.node.id}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Node name'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<SurveyNodeType>(
            initialValue: _selectedType,
            decoration: const InputDecoration(labelText: 'Node type'),
            items: SurveyNodeType.values
                .map(
                  (type) => DropdownMenuItem(
                    value: type,
                    child: Text(_nodeTypeLabel(type)),
                  ),
                )
                .toList(),
            onChanged: (type) {
              if (type != null) setState(() => _selectedType = type);
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  void _save() {
    final name = _nameController.text.trim();
    Navigator.pop(
      context,
      widget.node.copyWith(
        name: name.isEmpty ? widget.node.name : name,
        type: _selectedType,
      ),
    );
  }

  Future<void> _showTypePicker() async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (context) => CupertinoActionSheet(
        title: const Text('Node type'),
        actions: SurveyNodeType.values
            .map(
              (type) => CupertinoActionSheetAction(
                isDefaultAction: type == _selectedType,
                onPressed: () {
                  setState(() => _selectedType = type);
                  Navigator.pop(context);
                },
                child: Text(_nodeTypeLabel(type)),
              ),
            )
            .toList(),
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}

class _PlacedSurveyNode {
  const _PlacedSurveyNode({required this.node, this.marker, this.anchor});

  final SurveyNode node;
  final ARNode? marker;
  final ARPlaneAnchor? anchor;

  _PlacedSurveyNode copyWith({
    SurveyNode? node,
    ARNode? marker,
    ARPlaneAnchor? anchor,
    bool clearMarker = false,
  }) {
    return _PlacedSurveyNode(
      node: node ?? this.node,
      marker: clearMarker ? null : marker ?? this.marker,
      anchor: anchor ?? this.anchor,
    );
  }
}

class _PendingCloudAnchorResolution {
  const _PendingCloudAnchorResolution({
    required this.node,
    required this.completer,
  });

  final SurveyNode node;
  final Completer<ARPlaneAnchor> completer;
}

String _nodeTypeLabel(SurveyNodeType type) {
  return type.name[0].toUpperCase() + type.name.substring(1);
}

String _connectionTypeLabel(SurveyConnectionType type) {
  return switch (type) {
    SurveyConnectionType.corridor => 'Corridor',
    SurveyConnectionType.stairs => 'Stairs',
    SurveyConnectionType.elevator => 'Elevator',
  };
}

String _connectionEndpointLabel(String nodeId, Map<String, SurveyNode> nodes) {
  final node = nodes[nodeId];
  return node == null ? nodeId : '${node.name} (F${node.floor})';
}

class _UnsupportedPlatformView extends StatelessWidget {
  const _UnsupportedPlatformView();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Color(0xFF071014),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                defaultTargetPlatform == TargetPlatform.iOS
                    ? CupertinoIcons.device_phone_portrait
                    : Icons.phone_iphone,
                size: 56,
                color: Colors.white70,
              ),
              SizedBox(height: 16),
              Text(
                'AR camera preview requires an iPhone or Android device.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18),
              ),
              SizedBox(height: 8),
              Text(
                'Run ARCIS on a physical ARKit or ARCore device to see the live feed and place survey nodes.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.floor,
    required this.nodeCount,
    required this.canPlanRoute,
    required this.onPlanRoute,
  });

  final int floor;
  final int nodeCount;
  final bool canPlanRoute;
  final VoidCallback onPlanRoute;

  @override
  Widget build(BuildContext context) {
    final usesCupertino = defaultTargetPlatform == TargetPlatform.iOS;
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'ARCIS',
                style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2),
              ),
              SizedBox(height: 4),
              Text(
                'AR SURVEY MODE',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          key: const ValueKey('open-route-page'),
          tooltip: 'Plan a route',
          onPressed: canPlanRoute ? onPlanRoute : null,
          icon: const Icon(Icons.alt_route),
        ),
        const SizedBox(width: 8),
        DecoratedBox(
          decoration: BoxDecoration(
            color: usesCupertino
                ? CupertinoColors.tertiarySystemFill.resolveFrom(context)
                : Colors.black54,
            borderRadius: BorderRadius.circular(usesCupertino ? 16 : 20),
            border: Border.all(
              color: usesCupertino ? Colors.white12 : Colors.white24,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Text(
              'FLOOR $floor  •  NODES $nodeCount',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }
}

class _InstructionPanel extends StatelessWidget {
  const _InstructionPanel({
    required this.onMove,
    required this.onResize,
    required this.status,
    required this.isLoading,
    required this.nodes,
    required this.unanchoredNodeIds,
    required this.floors,
    required this.activeFloor,
    required this.floorNodes,
    required this.floorConnections,
    required this.connections,
    required this.routeStartNodeId,
    required this.routeDestinationNodeId,
    required this.activeRoute,
    required this.isGuidingRoute,
    required this.navigationStepIndex,
    required this.isConnecting,
    required this.connectingFromNodeId,
    required this.onRemove,
    required this.onEdit,
    required this.onConnect,
    required this.onReanchorNode,
    required this.onToggleConnecting,
    required this.onRemoveConnection,
    required this.onFloorChanged,
    required this.onChooseFloor,
    required this.onAddFloor,
    required this.onDeleteFloor,
    required this.onExport,
    required this.onClear,
  });

  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;
  final String status;
  final bool isLoading;
  final List<SurveyNode> nodes;
  final Set<String> unanchoredNodeIds;
  final List<SurveyFloor> floors;
  final int activeFloor;
  final List<SurveyNode> floorNodes;
  final List<SurveyConnection> floorConnections;
  final List<SurveyConnection> connections;
  final String? routeStartNodeId;
  final String? routeDestinationNodeId;
  final SurveyRoute? activeRoute;
  final bool isGuidingRoute;
  final int navigationStepIndex;
  final bool isConnecting;
  final String? connectingFromNodeId;
  final VoidCallback onRemove;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onConnect;
  final ValueChanged<int> onReanchorNode;
  final VoidCallback onToggleConnecting;
  final ValueChanged<SurveyConnection> onRemoveConnection;
  final ValueChanged<int> onFloorChanged;
  final VoidCallback onChooseFloor;
  final VoidCallback onAddFloor;
  final VoidCallback onDeleteFloor;
  final VoidCallback onExport;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final usesCupertino = defaultTargetPlatform == TargetPlatform.iOS;
    final lastNode = floorNodes.isEmpty ? null : floorNodes.last;
    final nodesById = {for (final node in nodes) node.id: node};
    final activeFloorName =
        floors
            .where((floor) => floor.number == activeFloor)
            .map((floor) => floor.name)
            .firstOrNull ??
        'Floor $activeFloor';
    String? focusedRouteNodeId;
    if (isGuidingRoute &&
        activeRoute != null &&
        activeRoute!.nodes.isNotEmpty) {
      final routeNodeIndex = navigationStepIndex
          .clamp(0, activeRoute!.nodes.length - 1)
          .toInt();
      final stepNode = activeRoute!.nodes[routeNodeIndex];
      if (stepNode.floor == activeFloor) {
        focusedRouteNodeId = stepNode.id;
      } else if (routeNodeIndex > 0 &&
          activeRoute!.nodes[routeNodeIndex - 1].floor == activeFloor) {
        focusedRouteNodeId = activeRoute!.nodes[routeNodeIndex - 1].id;
      }
    }

    return Container(
      key: const ValueKey('survey-control-panel'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: usesCupertino
            ? CupertinoColors.secondarySystemBackground
                  .resolveFrom(context)
                  .withValues(alpha: 0.94)
            : Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(usesCupertino ? 18 : 8),
        border: Border.all(
          color: usesCupertino ? Colors.white12 : Colors.white24,
        ),
      ),
      child: Column(
        children: [
          GestureDetector(
            key: const ValueKey('survey-panel-drag-handle'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) => onMove(details.delta),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  Icon(
                    usesCupertino
                        ? CupertinoIcons.line_horizontal_3
                        : Icons.drag_indicator,
                    size: 18,
                    color: Colors.white54,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'SURVEY PANEL',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status, style: const TextStyle(fontSize: 15)),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      usesCupertino
                          ? CupertinoButton(
                              alignment: Alignment.centerLeft,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              onPressed: isLoading ? null : onChooseFloor,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(CupertinoIcons.building_2_fill),
                                  const SizedBox(width: 8),
                                  Text(activeFloorName),
                                  const SizedBox(width: 8),
                                  const Icon(
                                    CupertinoIcons.chevron_down,
                                    size: 14,
                                  ),
                                ],
                              ),
                            )
                          : DropdownButtonFormField<int>(
                              key: ValueKey('active-floor-$activeFloor'),
                              initialValue:
                                  floors.any(
                                    (floor) => floor.number == activeFloor,
                                  )
                                  ? activeFloor
                                  : null,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Floor',
                              ),
                              items: floors
                                  .map(
                                    (floor) => DropdownMenuItem(
                                      value: floor.number,
                                      child: Text(floor.name),
                                    ),
                                  )
                                  .toList(),
                              onChanged: isLoading
                                  ? null
                                  : (floor) {
                                      if (floor != null) {
                                        onFloorChanged(floor);
                                      }
                                    },
                            ),
                      usesCupertino
                          ? CupertinoButton(
                              padding: const EdgeInsets.all(8),
                              onPressed: isLoading ? null : onAddFloor,
                              child: const Icon(CupertinoIcons.add_circled),
                            )
                          : IconButton(
                              onPressed: isLoading ? null : onAddFloor,
                              tooltip: 'Add next floor',
                              icon: const Icon(Icons.add),
                            ),
                      usesCupertino
                          ? CupertinoButton(
                              padding: const EdgeInsets.all(8),
                              onPressed: isLoading || floors.length <= 1
                                  ? null
                                  : onDeleteFloor,
                              child: const Icon(CupertinoIcons.trash),
                            )
                          : IconButton(
                              onPressed: isLoading || floors.length <= 1
                                  ? null
                                  : onDeleteFloor,
                              tooltip: 'Delete selected floor',
                              icon: const Icon(Icons.delete_outline),
                            ),
                    ],
                  ),
                  if (floorNodes.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    SurveyMapPreview(
                      nodes: floorNodes,
                      connections: floorConnections,
                      route: activeRoute,
                      startNodeId:
                          floorNodes.any((node) => node.id == routeStartNodeId)
                          ? routeStartNodeId
                          : null,
                      destinationNodeId:
                          floorNodes.any(
                            (node) => node.id == routeDestinationNodeId,
                          )
                          ? routeDestinationNodeId
                          : null,
                      focusedNodeId: focusedRouteNodeId,
                    ),
                  ],
                  if (nodes.length > 1) ...[
                    const SizedBox(height: 8),
                    usesCupertino
                        ? CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            onPressed: onToggleConnecting,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  isConnecting
                                      ? CupertinoIcons.check_mark
                                      : CupertinoIcons.link,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  isConnecting
                                      ? 'Done connecting'
                                      : 'Connect nodes',
                                ),
                              ],
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: onToggleConnecting,
                            icon: Icon(
                              isConnecting ? Icons.link_off : Icons.link,
                            ),
                            label: Text(
                              isConnecting
                                  ? 'Done connecting'
                                  : 'Connect nodes',
                            ),
                          ),
                  ],
                  if (lastNode != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      'LAST NODE  ${lastNode.name}\n'
                      'WORLD POSITION\n'
                      'X  ${lastNode.worldPosition.x.toStringAsFixed(3)} m\n'
                      'Y  ${lastNode.worldPosition.y.toStringAsFixed(3)} m\n'
                      'Z  ${lastNode.worldPosition.z.toStringAsFixed(3)} m',
                      style: const TextStyle(
                        color: Colors.white70,
                        height: 1.45,
                      ),
                    ),
                  ],
                  if (nodes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'CAPTURED NODES',
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...nodes.asMap().entries.map((entry) {
                      final isSelected = connectingFromNodeId == entry.value.id;
                      final needsAnchor = unanchoredNodeIds.contains(
                        entry.value.id,
                      );
                      void onPressed() => isConnecting
                          ? onConnect(entry.key)
                          : onEdit(entry.key);
                      final nodeRow = Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${entry.value.name}  •  ${_nodeTypeLabel(entry.value.type)}  •  F${entry.value.floor}',
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            Icon(
                              usesCupertino
                                  ? isConnecting
                                        ? isSelected
                                              ? CupertinoIcons
                                                    .largecircle_fill_circle
                                              : CupertinoIcons.circle
                                        : CupertinoIcons.pencil
                                  : isConnecting
                                  ? isSelected
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked
                                  : Icons.edit_outlined,
                              size: 15,
                            ),
                          ],
                        ),
                      );
                      return Row(
                        children: [
                          Expanded(
                            child: usesCupertino
                                ? CupertinoButton(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 3,
                                    ),
                                    alignment: Alignment.centerLeft,
                                    onPressed: onPressed,
                                    child: nodeRow,
                                  )
                                : InkWell(onTap: onPressed, child: nodeRow),
                          ),
                          if (needsAnchor)
                            IconButton(
                              key: ValueKey('anchor-${entry.value.id}'),
                              tooltip: 'Anchor ${entry.value.name}',
                              onPressed: () => onReanchorNode(entry.key),
                              icon: const Icon(
                                Icons.add_location_alt_outlined,
                                color: Color(0xFFFBBF24),
                                size: 19,
                              ),
                            ),
                        ],
                      );
                    }),
                  ],
                  if (connections.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'CONNECTED PATHS',
                      style: TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    ...connections.map(
                      (connection) => Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_connectionTypeLabel(connection.type)}  ·  ${_connectionEndpointLabel(connection.nodeAId, nodesById)}  ↔  ${_connectionEndpointLabel(connection.nodeBId, nodesById)}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          usesCupertino
                              ? CupertinoButton(
                                  padding: const EdgeInsets.all(8),
                                  onPressed: () =>
                                      onRemoveConnection(connection),
                                  child: const Icon(CupertinoIcons.link),
                                )
                              : IconButton(
                                  onPressed: () =>
                                      onRemoveConnection(connection),
                                  tooltip: 'Remove connection',
                                  icon: const Icon(Icons.link_off, size: 16),
                                ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: usesCupertino
                        ? CupertinoButton.filled(
                            onPressed: nodes.isEmpty ? null : onRemove,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(CupertinoIcons.arrow_uturn_left),
                                const SizedBox(width: 8),
                                const Text('Remove last node'),
                              ],
                            ),
                          )
                        : FilledButton.icon(
                            onPressed: nodes.isEmpty ? null : onRemove,
                            icon: const Icon(Icons.undo),
                            label: const Text('Remove last node'),
                          ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      usesCupertino
                          ? CupertinoButton(
                              onPressed: nodes.isEmpty ? null : onExport,
                              child: const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(CupertinoIcons.doc_text),
                                  SizedBox(width: 8),
                                  Text('Export JSON'),
                                ],
                              ),
                            )
                          : OutlinedButton.icon(
                              onPressed: nodes.isEmpty ? null : onExport,
                              icon: const Icon(Icons.data_object),
                              label: const Text('Export JSON'),
                            ),
                      usesCupertino
                          ? CupertinoButton(
                              padding: const EdgeInsets.all(8),
                              onPressed: nodes.isEmpty ? null : onClear,
                              child: const Icon(CupertinoIcons.trash),
                            )
                          : IconButton(
                              onPressed: nodes.isEmpty ? null : onClear,
                              tooltip: 'Clear survey',
                              icon: const Icon(Icons.delete_outline),
                            ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              key: const ValueKey('survey-panel-resize-handle'),
              behavior: HitTestBehavior.opaque,
              onPanUpdate: (details) => onResize(details.delta),
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  usesCupertino
                      ? CupertinoIcons.fullscreen
                      : Icons.open_in_full,
                  size: 18,
                  color: Colors.white54,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
