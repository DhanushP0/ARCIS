import Foundation
import ARCoreCloudAnchors

// Listener that can be attached to hosing or resolving processes
protocol CloudAnchorListener {
    // Callback to invoke when cloud anchor task finishes
    func onCloudTaskComplete(
        anchorName: String?,
        anchor: GARAnchor?,
        cloudState: GARCloudAnchorState
    )
    func onCloudTaskFailed(anchorId: String, errorMessage: String)
}

extension CloudAnchorListener {
    func onCloudTaskFailed(anchorId: String, errorMessage: String) {}
}

// Class for handling logic regarding the Google Cloud Anchor API
class CloudAnchorHandler: NSObject, GARSessionDelegate {
    private struct PendingResolve {
        let anchorId: String
        let future: GARResolveCloudAnchorFuture
        let startedAt: TimeInterval
        var lastDiagnosticTime: TimeInterval
    }

    private var session: GARSession
    private var pendingAnchors = [GARAnchor: (String?, CloudAnchorListener?)]()
    private var pendingResolveFutures = [UUID: PendingResolve]()
    private var receivedFrameCount = 0
    
    init(session: GARSession){
        self.session = session
    }
    
    func hostCloudAnchor(anchorName: String, anchor: ARAnchor, listener: CloudAnchorListener?) {
        do {
            let newAnchor = try self.session.hostCloudAnchor(anchor)
            // Register listener so it is invoked when the operation finishes
            pendingAnchors[newAnchor] = (anchorName, listener)
        } catch {
            print(error)
            listener?.onCloudTaskFailed(
                anchorId: anchorName,
                errorMessage: error.localizedDescription
            )
        }
    }
    
    func hostCloudAnchorWithTtl(anchorName: String, anchor: ARAnchor, listener: CloudAnchorListener?, ttl: Int) {
        do {
            let newAnchor = try self.session.hostCloudAnchor(anchor, ttlDays: ttl)
            // Register listener so it is invoked when the operation finishes
            pendingAnchors[newAnchor] = (anchorName, listener)
        } catch {
            print(error)
            listener?.onCloudTaskFailed(
                anchorId: anchorName,
                errorMessage: error.localizedDescription
            )
        }
    }
    
    func resolveCloudAnchor(anchorId: String, listener: CloudAnchorListener?) {
        print("ARCIS ARCore resolve requested for anchor \(anchorId)")
        let operationId = UUID()
        do {
            let future = try self.session.resolveCloudAnchor(
                anchorId,
                completionHandler: { [weak self] anchor, cloudState in
                    self?.pendingResolveFutures.removeValue(forKey: operationId)
                    print(
                        "ARCIS ARCore resolve completion for \(anchorId); "
                            + "state=\(cloudState.rawValue), "
                            + "hasAnchor=\(anchor != nil)"
                    )
                    guard cloudState == .success, let anchor = anchor else {
                        listener?.onCloudTaskFailed(
                            anchorId: anchorId,
                            errorMessage: "ARCore resolve completed with state "
                                + "\(cloudState.rawValue)."
                        )
                        return
                    }
                    listener?.onCloudTaskComplete(
                        anchorName: nil,
                        anchor: anchor,
                        cloudState: cloudState
                    )
                }
            )
            pendingResolveFutures[operationId] = PendingResolve(
                anchorId: anchorId,
                future: future,
                startedAt: ProcessInfo.processInfo.systemUptime,
                lastDiagnosticTime: ProcessInfo.processInfo.systemUptime
            )
            print("ARCIS ARCore resolve started for anchor \(anchorId)")
        } catch {
            print("ARCIS ARCore resolve could not start for \(anchorId): \(error)")
            listener?.onCloudTaskFailed(
                anchorId: anchorId,
                errorMessage: error.localizedDescription
            )
        }
        
    }

    func recordFrame(trackingState: String) {
        receivedFrameCount += 1
        let now = ProcessInfo.processInfo.systemUptime

        for operationId in Array(pendingResolveFutures.keys) {
            guard var pending = pendingResolveFutures[operationId],
                  now - pending.lastDiagnosticTime >= 5 else {
                continue
            }
            print(
                "ARCIS ARCore resolve still pending for \(pending.anchorId); "
                    + "elapsed=\(Int(now - pending.startedAt))s, "
                    + "ARKit tracking=\(trackingState), "
                    + "frames=\(receivedFrameCount), "
                    + "future=\(pending.future.state)"
            )
            pending.lastDiagnosticTime = now
            pendingResolveFutures[operationId] = pending
        }
    }
        
    func session(_ session: GARSession, didHost anchor: GARAnchor) {
        completeTask(for: anchor, callback: "didHost")
    }
    
    func session(_ session: GARSession, didFailToHost anchor: GARAnchor) {
        completeTask(for: anchor, callback: "didFailToHost")
    }
    
    func session(_ session: GARSession, didResolve anchor: GARAnchor) {
        completeTask(for: anchor, callback: "didResolve")
    }
    
    func session(_ session: GARSession, didFailToResolve anchor: GARAnchor) {
        completeTask(for: anchor, callback: "didFailToResolve")
    }

    private func completeTask(for anchor: GARAnchor, callback: String) {
        let pending = pendingAnchors.removeValue(forKey: anchor)
        let cloudAnchorId = anchor.cloudIdentifier ?? "(no cloud ID)"
        print(
            "ARCIS ARCore \(callback) callback for \(cloudAnchorId); "
                + "state=\(anchor.cloudState.rawValue), "
                + "pendingMatch=\(pending != nil)"
        )
        guard let (anchorName, listener) = pending else {
            return
        }
        listener?.onCloudTaskComplete(
            anchorName: anchorName,
            anchor: anchor,
            cloudState: anchor.cloudState
        )
    }
    
    // Remove all listeners
    func clearListeners() {
        pendingAnchors.removeAll()
        pendingResolveFutures.values.forEach { $0.future.cancel() }
        pendingResolveFutures.removeAll()
    }
}
