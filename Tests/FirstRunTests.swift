import Foundation

@main struct FirstRunTests {
    @MainActor static func main() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = "vless://11111111-1111-1111-1111-111111111111@first.example.invalid:443?security=tls#First"
        let second = "vless://22222222-2222-2222-2222-222222222222@second.example.invalid:443?security=tls#Second"
        let subscription = first + "\n" + second + "\n"
        let nodes = try Subscription.nodes(subscription)
        func makeStore(_ name: String) -> StateStore {
            StateStore(directory: root.appendingPathComponent(name), legacyDirectory: root.appendingPathComponent("none"), runtimeHashFile: root.appendingPathComponent("no-runtime"))
        }
        func model(_ store: StateStore) -> VPNController {
            let result = VPNController(store: store)
            result.notificationsEnabled = false
            result.happCompatibilityEnabled = false
            result.autoFailoverEnabled = false
            return result
        }
        func wait(_ controller: VPNController) async throws {
            for _ in 0..<300 {
                if !controller.isBusy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Setup did not finish within three seconds")
        }

        SystemService.reset()
        let componentStore = makeStore("component-first")
        let component = model(componentStore)
        component.installInitialComponent()
        component.installInitialComponent()
        try await wait(component)
        let provisioned = try componentStore.load()
        precondition(component.isInstalled && !component.isRunning && component.showConnection)
        precondition(provisioned.subscription.isEmpty && provisioned.selectedNodeID == nil && !provisioned.desiredOn)
        precondition(SystemService.installs == 1 && SystemService.actions.isEmpty && SubscriptionFetcher.requests == 0,
                     "First launch must install the stopped component before requesting a subscription")
        SubscriptionFetcher.response = Data(subscription.utf8)
        component.candidateURL = "https://subscription.example.invalid/test"
        component.applySubscription()
        try await wait(component)
        let connectedAfterInstall = try componentStore.load()
        precondition(connectedAfterInstall.selectedNodeID == nodes[0].id && connectedAfterInstall.desiredOn)
        precondition(SystemService.installs == 1 && SystemService.deployments == 1 && SystemService.actions == ["on"],
                     "Adding the subscription must connect without a second administrator installation")
        component.installInitialComponent()
        precondition(!component.isBusy && SystemService.installs == 1)

        SystemService.reset()
        SystemService.cancelInstall = true
        let cancelledComponent = model(makeStore("component-retry"))
        cancelledComponent.installInitialComponent()
        try await wait(cancelledComponent)
        precondition(!cancelledComponent.isInstalled && cancelledComponent.showConnection && !cancelledComponent.failureReport.isEmpty)
        precondition(SubscriptionFetcher.requests == 0 && SystemService.actions.isEmpty)
        SystemService.cancelInstall = false
        cancelledComponent.installInitialComponent()
        try await wait(cancelledComponent)
        precondition(cancelledComponent.isInstalled && !cancelledComponent.isRunning && cancelledComponent.failureReport.isEmpty)

        SystemService.reset()
        let freshStore = makeStore("fresh")
        let fresh = model(freshStore)
        precondition(fresh.showConnection && fresh.isInitialSetup && !fresh.canApplySubscription)
        SubscriptionFetcher.response = Data(subscription.utf8)
        fresh.candidateURL = "  https://subscription.example.invalid/test  \n"
        precondition(fresh.canApplySubscription, "A pasted URL must enable setup without loading nodes first")
        fresh.openSetup()
        precondition(fresh.candidateURL == "  https://subscription.example.invalid/test  \n", "Focusing an open setup window must preserve its draft")
        fresh.applySubscription()
        fresh.applySubscription()
        try await wait(fresh)
        let saved = try freshStore.load()
        precondition(saved.subscriptionURL == "https://subscription.example.invalid/test")
        precondition(saved.selectedNodeID == nodes.first?.id && saved.desiredOn)
        precondition(!fresh.showConnection && fresh.failureReport.isEmpty)
        precondition(fresh.selectedNode?.id == nodes[0].id)
        precondition(fresh.unselectedNodes.map(\.id) == [nodes[1].id], "The pinned server must not be duplicated in the scrollable list")
        precondition(SubscriptionFetcher.requests == 1 && SystemService.installs == 1 && SystemService.actions == ["on"], "Double clicks must not duplicate the setup operation")

        SystemService.reset()
        let directStore = makeStore("direct")
        let direct = model(directStore)
        direct.candidateURL = first
        direct.applySubscription()
        try await wait(direct)
        let directSaved = try directStore.load()
        precondition(directSaved.selectedNodeID == nodes.first?.id)
        precondition(SubscriptionFetcher.requests == 0, "Direct VLESS links must not require an HTTP fetch")

        SystemService.reset()
        let retryStore = makeStore("retry")
        let retry = model(retryStore)
        retry.candidateURL = "http://subscription.example.invalid/test"
        retry.applySubscription()
        try await wait(retry)
        precondition(SystemService.installs == 0 && !retry.failureReport.isEmpty)
        let invalidSaved = try retryStore.load()
        precondition(invalidSaved.subscription.isEmpty)
        retry.candidateURL = "https://subscription.example.invalid/test"
        SubscriptionFetcher.failure = true
        retry.applySubscription()
        try await wait(retry)
        precondition(SystemService.installs == 0 && retry.showConnection && retry.canApplySubscription)
        SubscriptionFetcher.failure = false
        SubscriptionFetcher.response = Data("not a subscription".utf8)
        retry.applySubscription()
        try await wait(retry)
        precondition(SystemService.installs == 0 && retry.showConnection)
        SubscriptionFetcher.response = Data(subscription.utf8)
        SystemService.cancelInstall = true
        retry.applySubscription()
        try await wait(retry)
        let cancelledSaved = try retryStore.load()
        precondition(cancelledSaved.subscription.isEmpty)
        precondition(retry.showConnection && retry.canApplySubscription && SystemService.actions.isEmpty)
        let requestsBeforeRetry = SubscriptionFetcher.requests
        SystemService.cancelInstall = false
        retry.applySubscription()
        try await wait(retry)
        let retriedSaved = try retryStore.load()
        precondition(retriedSaved.selectedNodeID == nodes.first?.id)
        precondition(!retry.showConnection && SubscriptionFetcher.requests == requestsBeforeRetry, "Retrying a cancelled install should reuse the validated subscription")

        SystemService.reset()
        SystemService.installedValue = true
        let existingStore = makeStore("existing")
        var old = SavedState()
        old.subscription = subscription
        old.subscriptionURL = "https://subscription.example.invalid/old"
        old.selectedNodeID = nodes[1].id
        try existingStore.save(old)
        let existing = model(existingStore)
        precondition(existing.selectedNode?.id == nodes[1].id)
        precondition(existing.unselectedNodes.map(\.id) == [nodes[0].id], "Remaining servers must keep subscription order")
        existing.openSetup()
        existing.candidateURL = "https://subscription.example.invalid/new"
        existing.applySubscription()
        try await wait(existing)
        let existingSaved = try existingStore.load()
        precondition(existingSaved.selectedNodeID == nodes[1].id, "Editing a URL must retain the existing matching server")
        precondition(SystemService.installs == 0 && SystemService.deployments == 1)
        existing.openSetup()
        SubscriptionFetcher.response = Data(first.utf8)
        existing.candidateURL = "https://subscription.example.invalid/changed"
        existing.applySubscription()
        try await wait(existing)
        precondition(existing.candidateID == nil && !existing.failureReport.isEmpty && existing.showConnection)
        let missingNodeSaved = try existingStore.load()
        precondition(missingNodeSaved.selectedNodeID == nodes[1].id)
        existing.candidateID = nodes[0].id
        existing.applySubscription()
        try await wait(existing)
        let replacementSaved = try existingStore.load()
        precondition(replacementSaved.selectedNodeID == nodes[0].id)
        SystemService.reset()
        SystemService.installedValue = true
        let selectionStore = makeStore("selection")
        try selectionStore.save(old)
        let selection = model(selectionStore)
        selection.selectNode(nodes[0].id)
        try await wait(selection)
        let connected = try selectionStore.load()
        precondition(connected.selectedNodeID == nodes[0].id && connected.desiredOn && SystemService.runningValue, "Clicking a server must connect even when the VPN was off")
        precondition(SystemService.installs == 0 && SystemService.actions == ["on"])
        let deploymentsBeforeClick = SystemService.deployments
        selection.selectNode(nodes[0].id)
        precondition(!selection.isBusy && SystemService.deployments == deploymentsBeforeClick, "Clicking an already connected server must not restart it")
        for _ in 0..<300 {
            if !selection.testingNodes { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!selection.testingNodes)
        selection.probeResults["unrelated-server"] = NodeProbeResult(outcome: .reachable, latencyMilliseconds: 10, method: .icmp)
        selection.testNodes()
        selection.testNodes()
        precondition(selection.testingNodes)
        for _ in 0..<300 {
            if !selection.testingNodes { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(!selection.testingNodes && nodes.allSatisfy { selection.probeResults[$0.id] != nil })
        precondition(selection.state.selectedNodeID == nodes[0].id, "Checking latency must not change the selected server")
        precondition(AppLogger.shared.contents().split(separator: "\n").last(where: { $0.hasPrefix("node latency check completed;") }) == "node latency check completed; reachable=0/2",
                     "A batch summary must exclude results cached for other subscriptions")
        SystemService.routingUpdateValue = Date(timeIntervalSince1970: 1700000000)
        selection.loadAutomaticRoutingUpdate()
        precondition(selection.automaticRoutingLastUpdate == SystemService.routingUpdateValue)
        SystemService.routingUpdateValue = nil
        selection.loadAutomaticRoutingUpdate()
        precondition(selection.automaticRoutingLastUpdate == nil, "A missing date must not retain stale presentation state")

        print("first run: component-first setup, no second install prompt, HTTPS/VLESS, first-node selection, serialization, cancellation retry and node preservation passed")
    }
}
