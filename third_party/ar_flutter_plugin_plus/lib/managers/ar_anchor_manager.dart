import 'package:ar_flutter_plugin_plus/models/ar_anchor.dart';
import 'package:flutter/services.dart';

// Type definitions to enforce a consistent use of the API
typedef AnchorUploadedHandler = void Function(ARAnchor arAnchor);
typedef AnchorDownloadedHandler = ARAnchor Function(
    Map<String, dynamic> serializedAnchor);
typedef AnchorDownloadFailedHandler = void Function(
    String cloudAnchorId, String message);
typedef AnchorUploadFailedHandler = void Function(
    String anchorName, String message);

/// Handles all anchor-related functionality of an [ARView], including configuration and usage of collaborative sessions
class ARAnchorManager {
  /// Platform channel used for communication from and to [ARAnchorManager]
  late MethodChannel _channel;

  /// Debugging status flag. If true, all platform calls are printed. Defaults to false.
  final bool debug;

  /// Reference to all anchors that are being uploaded to the google cloud anchor API
  List<ARAnchor> pendingAnchors = [];

  /// Callback that is triggered once an anchor has successfully been uploaded to the google cloud anchor API
  AnchorUploadedHandler? onAnchorUploaded;

  /// Callback that is triggered once an anchor has successfully been downloaded from the google cloud anchor API and resolved within the current scene
  AnchorDownloadedHandler? onAnchorDownloaded;

  /// Callback triggered when resolving a Cloud Anchor fails.
  AnchorDownloadFailedHandler? onAnchorDownloadFailed;

  /// Callback triggered when hosting a Cloud Anchor fails.
  AnchorUploadFailedHandler? onAnchorUploadFailed;

  ARAnchorManager(int id, {this.debug = false}) {
    _channel = MethodChannel('aranchors_$id');
    _channel.setMethodCallHandler(_platformCallHandler);
    if (debug) {
      print("ARAnchorManager initialized");
    }
  }

  /// Activates collaborative AR mode (using Google Cloud Anchors)
  initGoogleCloudAnchorMode() async {
    _channel.invokeMethod<bool>('initGoogleCloudAnchorMode', {});
  }

  Future<dynamic> _platformCallHandler(MethodCall call) async {
    if (debug) {
      print('_platformCallHandler call ${call.method} ${call.arguments}');
    }
    try {
      switch (call.method) {
        case 'onError':
          print(call.arguments);
          break;
        case 'onCloudAnchorUploaded':
          final name = call.arguments["name"];
          final cloudanchorid = call.arguments["cloudanchorid"];
          print(
              "UPLOADED ANCHOR WITH ID: " + cloudanchorid + ", NAME: " + name);
          final currentAnchor =
              pendingAnchors.where((element) => element.name == name).first;
          // Update anchor with cloud anchor ID
          (currentAnchor as ARPlaneAnchor).cloudanchorid = cloudanchorid;
          // Remove anchor from list of pending anchors
          pendingAnchors.remove(currentAnchor);
          // Notify callback
          if (onAnchorUploaded != null) {
            onAnchorUploaded!(currentAnchor);
          }
          break;
        case 'onCloudAnchorUploadFailed':
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final anchorName = arguments['name'] as String? ?? '';
          final message = arguments['message'] as String? ??
              'Cloud Anchor hosting failed.';
          pendingAnchors.removeWhere((anchor) => anchor.name == anchorName);
          if (onAnchorUploadFailed != null) {
            onAnchorUploadFailed!(anchorName, message);
          } else {
            print('Cloud Anchor hosting failed: $message');
          }
          break;
        case "onAnchorDownloadSuccess":
          final serializedAnchor = call.arguments;
          if (onAnchorDownloaded != null) {
            ARAnchor anchor = onAnchorDownloaded!(
                Map<String, dynamic>.from(serializedAnchor));
            return anchor.name;
          } else {
            return serializedAnchor["name"];
          }
        case "onCloudAnchorDownloadFailed":
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final cloudAnchorId = arguments["cloudanchorid"] as String? ?? "";
          final message = arguments["message"] as String? ??
              "Cloud Anchor resolution failed.";
          if (onAnchorDownloadFailed != null) {
            onAnchorDownloadFailed!(cloudAnchorId, message);
          } else {
            print("Cloud Anchor resolution failed: $message");
          }
          break;
        default:
          if (debug) {
            print('Unimplemented method ${call.method} ');
          }
      }
    } catch (e) {
      print('Error caught: $e');
    }
    return Future.value();
  }

  /// Add given anchor to the underlying AR scene
  Future<bool?> addAnchor(ARAnchor anchor) async {
    try {
      return await _channel.invokeMethod<bool>('addAnchor', anchor.toJson());
    } on PlatformException {
      return false;
    }
  }

  /// Remove given anchor and all its children from the AR Scene
  removeAnchor(ARAnchor anchor) {
    _channel.invokeMethod<String>('removeAnchor', {'name': anchor.name});
  }

  /// Upload given anchor from the underlying AR scene to the Google Cloud Anchor API
  Future<bool?> uploadAnchor(ARAnchor anchor) async {
    try {
      final response =
          await _channel.invokeMethod<bool>('uploadAnchor', anchor.toJson());
      pendingAnchors.add(anchor);
      return response;
    } on PlatformException {
      return false;
    }
  }

  /// Try to download anchor with the given ID from the Google Cloud Anchor API and add it to the scene
  Future<bool?> downloadAnchor(String cloudanchorid) async {
    print("TRYING TO DOWNLOAD ANCHOR WITH ID $cloudanchorid");
    return await _channel
        .invokeMethod<bool>('downloadAnchor', {"cloudanchorid": cloudanchorid});
  }
}
