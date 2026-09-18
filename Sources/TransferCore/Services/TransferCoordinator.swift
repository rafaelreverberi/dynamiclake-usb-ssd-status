import Foundation

public final class TransferCoordinator: TransferProviderDelegate {
    public var onChange: (([Transfer]) -> Void)?
    public private(set) var transfers: [String: Transfer] = [:]

    private var aliases: [String: String] = [:]
    private let queue = DispatchQueue(label: "com.rafaelreverberi.usb-ssd-status.coordinator")
    /// Finder publishes one Progress object per file for folder copies. Without
    /// coalescing, each file completion would flash `Transfer complete` before
    /// the next file starts. A new Foundation transfer on the same volume
    /// shortly after a completion therefore continues that logical transfer.
    private let foundationContinuationWindow: TimeInterval = 2.0

    public init() {}

    public var snapshot: [Transfer] {
        queue.sync { sorted(Array(transfers.values)) }
    }

    public func transferProvider(_ provider: TransferProvider, emitted event: TransferProviderEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            switch event {
            case .updated(let transfer): self.upsert(transfer)
            case .removed(let id, let finalState): self.finish(providerID: id, state: finalState)
            }
        }
    }

    public func handleVolumeDisconnected(_ volumeID: String) {
        queue.async { [weak self] in
            guard let self else { return }
            var changed = false
            for (id, var transfer) in transfers where transfer.state.isActive &&
                (transfer.sourceVolumeID == volumeID || transfer.destinationVolumeID == volumeID) {
                transfer.state = .volumeDisconnected
                transfer.updatedAt = Date()
                transfer.completedAt = Date()
                transfers[id] = transfer
                changed = true
            }
            if changed { publish() }
        }
    }

    public func hasActiveTransfer(for volumeID: String) -> Bool {
        queue.sync {
            transfers.values.contains {
                $0.state.isActive && ($0.sourceVolumeID == volumeID || $0.destinationVolumeID == volumeID)
            }
        }
    }

    private func upsert(_ incoming: Transfer) {
        if let canonicalID = aliases[incoming.id], let current = transfers[canonicalID] {
            transfers[canonicalID] = merged(current, incoming, canonicalID: canonicalID)
            publish()
            return
        }
        if let current = transfers[incoming.id] {
            transfers[incoming.id] = merged(current, incoming, canonicalID: incoming.id)
            publish()
            return
        }
        if let continuation = continuationCandidate(for: incoming) {
            aliases[incoming.id] = continuation.id
            transfers[continuation.id] = continued(continuation, with: incoming)
            publish()
            return
        }
        if let match = correlationCandidate(for: incoming) {
            aliases[incoming.id] = match.id
            transfers[match.id] = merged(match, incoming, canonicalID: match.id)
        } else {
            transfers[incoming.id] = incoming
        }
        publish()
    }

    private func finish(providerID: String, state: TransferState) {
        let canonicalID = aliases[providerID] ?? providerID
        guard var transfer = transfers[canonicalID] else { return }

        // FSEvents settling means only "activity stopped". Never turn that into
        // a semantic completion when it is the only evidence available.
        if transfer.provider == .fsevents {
            transfers.removeValue(forKey: canonicalID)
            aliases = aliases.filter { $0.value != canonicalID }
            publish()
            return
        }

        transfer.state = state
        transfer.updatedAt = Date()
        transfer.completedAt = Date()
        if state == .completed { transfer.fractionCompleted = transfer.fractionCompleted ?? 1 }
        transfers[canonicalID] = transfer
        publish()
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.transfers[canonicalID]?.state.isActive == false else { return }
            self.transfers.removeValue(forKey: canonicalID)
            self.aliases = self.aliases.filter { $0.value != canonicalID }
            self.publish()
        }
    }

    private func correlationCandidate(for incoming: Transfer) -> Transfer? {
        let candidates = transfers.values.filter { current in
            guard current.state.isActive, incoming.state.isActive,
                  current.provider != incoming.provider,
                  abs(current.updatedAt.timeIntervalSince(incoming.updatedAt)) <= 8 else { return false }

            if let lhs = current.destinationURL?.standardizedFileURL.path,
               let rhs = incoming.destinationURL?.standardizedFileURL.path {
                return lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
            }
            if let lhs = current.destinationVolumeID, let rhs = incoming.destinationVolumeID, lhs == rhs {
                return current.provider == .fsevents || incoming.provider == .fsevents
            }
            // AX usually has no path. Only merge it when exactly one stronger
            // transfer is already active, otherwise simultaneous copies remain separate.
            if incoming.provider == .finderAccessibility || current.provider == .finderAccessibility {
                let stronger = transfers.values.filter { $0.state.isActive && $0.provider.priority > 1 }
                return stronger.count == 1
            }
            return false
        }
        return candidates.max { $0.provider.priority < $1.provider.priority }
    }

    private func continuationCandidate(for incoming: Transfer) -> Transfer? {
        guard incoming.provider == .foundationProgress,
              incoming.state.isActive,
              let volumeID = incoming.destinationVolumeID ?? incoming.sourceVolumeID else { return nil }
        let reference = incoming.updatedAt
        return transfers.values
            .filter { current in
                guard current.provider == .foundationProgress,
                      !current.state.isActive,
                      current.state == .completed,
                      (current.destinationVolumeID == volumeID || current.sourceVolumeID == volumeID),
                      let completedAt = current.completedAt else { return false }
                return reference.timeIntervalSince(completedAt) >= 0 &&
                    reference.timeIntervalSince(completedAt) <= foundationContinuationWindow
            }
            .max { ($0.completedAt ?? $0.updatedAt) < ($1.completedAt ?? $1.updatedAt) }
    }

    private func continued(_ terminal: Transfer, with incoming: Transfer) -> Transfer {
        var result = incoming
        result.id = terminal.id
        result.sourceURL = incoming.sourceURL ?? terminal.sourceURL
        result.destinationURL = incoming.destinationURL ?? terminal.destinationURL
        result.sourceVolumeID = incoming.sourceVolumeID ?? terminal.sourceVolumeID
        result.destinationVolumeID = incoming.destinationVolumeID ?? terminal.destinationVolumeID
        result.volumeName = incoming.volumeName ?? terminal.volumeName
        result.startedAt = min(terminal.startedAt, incoming.startedAt)
        result.updatedAt = max(terminal.updatedAt, incoming.updatedAt)
        result.confidence = max(terminal.confidence, incoming.confidence)
        result.completedAt = nil
        result.failureDescription = nil
        return result
    }

    private func merged(_ existing: Transfer, _ incoming: Transfer, canonicalID: String) -> Transfer {
        let preferred = incoming.provider.priority >= existing.provider.priority ? incoming : existing
        let secondary = incoming.provider.priority >= existing.provider.priority ? existing : incoming
        var result = preferred
        result.id = canonicalID
        result.sourceURL = preferred.sourceURL ?? secondary.sourceURL
        result.destinationURL = preferred.destinationURL ?? secondary.destinationURL
        result.sourceVolumeID = preferred.sourceVolumeID ?? secondary.sourceVolumeID
        result.destinationVolumeID = preferred.destinationVolumeID ?? secondary.destinationVolumeID
        result.volumeName = preferred.volumeName ?? secondary.volumeName
        result.currentFileName = preferred.currentFileName ?? secondary.currentFileName
        result.fractionCompleted = preferred.fractionCompleted ?? secondary.fractionCompleted
        result.bytesCompleted = preferred.bytesCompleted ?? secondary.bytesCompleted
        result.bytesTotal = preferred.bytesTotal ?? secondary.bytesTotal
        result.filesCompleted = preferred.filesCompleted ?? secondary.filesCompleted
        result.filesTotal = preferred.filesTotal ?? secondary.filesTotal
        result.bytesPerSecond = preferred.bytesPerSecond ?? secondary.bytesPerSecond
        result.estimatedSecondsRemaining = preferred.estimatedSecondsRemaining ?? secondary.estimatedSecondsRemaining
        result.startedAt = min(existing.startedAt, incoming.startedAt)
        result.updatedAt = max(existing.updatedAt, incoming.updatedAt)
        result.confidence = max(existing.confidence, incoming.confidence)
        if result.state.isActive {
            result.completedAt = nil
            result.failureDescription = nil
        }
        return result
    }

    private func publish() {
        let value = sorted(Array(transfers.values))
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }

    private func sorted(_ values: [Transfer]) -> [Transfer] {
        values.sorted {
            if $0.state.isActive != $1.state.isActive { return $0.state.isActive }
            return $0.updatedAt > $1.updatedAt
        }
    }
}
