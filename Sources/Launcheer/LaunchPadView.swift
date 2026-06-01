import GameController
import SwiftUI
import UniformTypeIdentifiers

struct LaunchPadView: View {
    @EnvironmentObject private var library: AppLibrary
    @State private var query = ""
    @State private var page = LauncherPageMemory.load()
    @State private var draggingItemID: String?
    @State private var draggingSourceFolderID: String?
    @State private var dropTarget: LauncherDropTarget?
    @State private var openedFolder: LaunchFolder?
    @State private var pageDragOffset: CGFloat = 0
    @State private var canDismissByBackground = false
    @State private var dragCleanupTask: Task<Void, Never>?
    @State private var selectedItemID: String?
    @State private var selectedSlotIndex: Int?
    @State private var isEditingApps = false
    @State private var localizationRevision = 0
    @FocusState private var searchFocused: Bool

    private var filteredItems: [LauncherItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return library.items }
        let tokens = trimmed.localizedLowercase.split(separator: " ").map(String.init)
        return library.items.filter { item in
            tokens.allSatisfy { item.searchText.contains($0) }
        }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = GridMetrics(size: proxy.size)
            let pageCount = max(1, Int(ceil(Double(filteredItems.count) / Double(metrics.pageSize))))
            let contentWidth = max(0, proxy.size.width)
            let activeFolder = currentOpenedFolder

            ZStack {
                BackdropView()
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if openedFolder != nil {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                openedFolder = nil
                            }
                        } else if isEditingApps {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                                isEditingApps = false
                            }
                        } else if canDismissByBackground {
                            LauncherCommands.hide()
                        }
                    }

                if activeFolder != nil {
                    Color.black.opacity(0.16)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if activeFolder == nil {
                    VStack(spacing: 26) {
                        SearchBar(text: $query)
                            .focused($searchFocused)
                            .frame(width: min(360, max(300, proxy.size.width * 0.24)))
                            .padding(.top, 42)

                        ZStack {
                            if library.isLoading {
                                ProgressView()
                                    .controlSize(.large)
                            } else if filteredItems.isEmpty {
                                EmptyState(query: query)
                            } else {
                                PageStrip(
                                    items: filteredItems,
                                    metrics: metrics,
                                    page: page,
                                    pageCount: pageCount,
                                    width: contentWidth,
                                    dragEnabled: query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isEditingApps,
                                    draggingItemID: $draggingItemID,
                                    draggingSourceFolderID: $draggingSourceFolderID,
                                    dropTarget: $dropTarget,
                                    selectedItemID: selectedItemID,
                                    isEditingApps: isEditingApps,
                                    pageDragOffset: pageDragOffset,
                                    launch: library.launch,
                                    openFolder: openFolder,
                                    beginEditing: beginEditingApps,
                                    requestTrash: confirmMoveToTrash,
                                    blankTap: handleBlankTap,
                                    closeFolder: { openedFolder = nil }
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        PageControls(
                            page: page,
                            pageCount: pageCount,
                            previous: { previousPage(pageCount: pageCount) },
                            next: { nextPage(pageCount: pageCount) },
                            select: { selectedPage in
                                goToPage(selectedPage, pageCount: pageCount)
                            }
                        )
                        .padding(.bottom, 92)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }

                if let activeFolder {
                    FolderFullScreenView(
                        folder: activeFolder,
                        metrics: metrics,
                        availableSize: proxy.size,
                        draggingItemID: $draggingItemID,
                        draggingSourceFolderID: $draggingSourceFolderID,
                        dropTarget: $dropTarget,
                        isEditingApps: isEditingApps,
                        launch: library.launch,
                        beginEditing: beginEditingApps,
                        endEditing: endEditingApps,
                        requestTrash: confirmMoveToTrash,
                        close: { openedFolder = nil },
                        closeForDragOut: { openedFolder = nil }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .overlay(alignment: .topTrailing) {
                if activeFolder == nil {
                    HeaderControls(
                        reload: {
                            Task { await library.reload() }
                        }
                    )
                    .padding(.top, 24)
                    .padding(.trailing, 28)
                }
            }
            .overlay(alignment: .bottom) {
                if let error = library.lastLaunchError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.52), in: Capsule())
                        .padding(.bottom, 68)
                }
            }
            .background {
                TrackpadPageMonitor(
                    canGoPrevious: activeFolder == nil && page > 0,
                    canGoNext: activeFolder == nil && page < pageCount - 1,
                    maxInteractiveOffset: metrics.iconSize * 0.14,
                    pageTurnDistanceThreshold: metrics.iconSize * 0.2 * 0.78,
                    dragChanged: { offset in
                        pageDragOffset = offset
                    },
                    dragEnded: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            pageDragOffset = 0
                        }
                    },
                    previous: { previousPage(pageCount: pageCount) },
                    next: { nextPage(pageCount: pageCount) }
                )
            }
            .background {
                ExternalInputBridge { command in
                    handleExternalInput(command, metrics: metrics, pageCount: pageCount)
                }
            }
            .id(localizationRevision)
            .onReceive(NotificationCenter.default.publisher(for: .languageSettingsChanged)) { _ in
                localizationRevision += 1
            }
            .onChange(of: metrics.pageSize) {
                clampPage(pageCount: pageCount)
            }
            .onChange(of: pageCount) {
                clampPage(pageCount: pageCount)
            }
            .onChange(of: page) {
                if !isSearching {
                    LauncherPageMemory.save(page)
                }
                stabilizeSelectionOnCurrentPage(metrics: metrics)
            }
            .onChange(of: query) {
                selectedItemID = nil
                selectedSlotIndex = nil
                isEditingApps = false
                restorePageForCurrentQuery(pageCount: pageCount)
            }
            .onAppear {
                clampPage(pageCount: pageCount)
            }
        }
        .onAppear {
            searchFocused = true
        }
        .task {
            canDismissByBackground = false
            try? await Task.sleep(nanoseconds: 650_000_000)
            canDismissByBackground = true
        }
        .onChange(of: draggingItemID) {
            scheduleDragCleanupIfNeeded()
        }
        .onChange(of: filteredItems.map(\.id)) {
            reconcileSelection()
        }
        .onExitCommand {
            if isEditingApps {
                endEditingApps()
            } else {
                LauncherCommands.hide()
            }
        }
        .keyboardShortcut("f", modifiers: [.command])
    }

    private func previousPage(pageCount: Int) {
        guard page > 0 else { return }
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32)) {
            page -= 1
        }
    }

    private func nextPage(pageCount: Int) {
        guard page < pageCount - 1 else { return }
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32)) {
            page += 1
        }
    }

    private func goToPage(_ targetPage: Int, pageCount: Int) {
        let target = min(max(targetPage, 0), pageCount - 1)
        guard target != page else { return }
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32)) {
            page = target
        }
    }

    private func handleExternalInput(_ command: ExternalNavigationCommand, metrics: GridMetrics, pageCount: Int) {
        guard draggingItemID == nil else { return }

        switch command {
        case .back:
            if isEditingApps {
                withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                    isEditingApps = false
                }
            } else if openedFolder != nil {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                    openedFolder = nil
                }
            } else {
                LauncherCommands.hide()
            }
        case .confirm:
            guard openedFolder == nil else { return }
            guard !searchFocused else { return }
            guard !isEditingApps else { return }
            if selectedItemID == nil {
                selectInitialItem(metrics: metrics)
            } else {
                activateSelectedItem()
            }
        case .left, .right, .up, .down:
            guard openedFolder == nil, !filteredItems.isEmpty else { return }
            searchFocused = false
            moveSelection(command, metrics: metrics, pageCount: pageCount)
        }
    }

    private func moveSelection(_ command: ExternalNavigationCommand, metrics: GridMetrics, pageCount: Int) {
        let pageSize = metrics.pageSize
        let start = min(page * pageSize, max(0, filteredItems.count - 1))
        let end = min(start + pageSize, filteredItems.count) - 1
        guard start <= end else { return }

        let currentIndex: Int
        if let selectedItemID,
           let selectedIndex = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
           selectedIndex >= start,
           selectedIndex <= end {
            currentIndex = selectedIndex
        } else {
            currentIndex = preferredIndexOnCurrentPage(metrics: metrics, start: start, end: end)
        }

        let localIndex = currentIndex - start
        let column = localIndex % metrics.columnCount
        let rowStart = currentIndex - column
        let rowEnd = min(rowStart + metrics.columnCount - 1, end)

        switch command {
        case .left:
            if column > 0, currentIndex > start {
                selectItem(at: currentIndex - 1)
            } else if page > 0 {
                let previousPage = page - 1
                let previousStart = previousPage * pageSize
                let previousEnd = min(previousStart + pageSize, filteredItems.count) - 1
                let targetSlot = rowEndSlot(metrics: metrics, preferredSlot: localIndex)
                guard targetSlot <= previousEnd - previousStart else { return }
                selectedSlotIndex = targetSlot
                selectedItemID = filteredItems[previousStart + targetSlot].id
                goToPage(previousPage, pageCount: pageCount)
            }
        case .right:
            if currentIndex < rowEnd {
                selectItem(at: currentIndex + 1)
            } else if page < pageCount - 1 {
                let nextPage = page + 1
                let nextStart = min(nextPage * pageSize, filteredItems.count - 1)
                let nextEnd = min(nextStart + pageSize, filteredItems.count) - 1
                let targetSlot = rowStartSlot(metrics: metrics, preferredSlot: localIndex)
                guard targetSlot <= nextEnd - nextStart else { return }
                selectedSlotIndex = targetSlot
                selectedItemID = filteredItems[nextStart + targetSlot].id
                goToPage(nextPage, pageCount: pageCount)
            }
        case .up:
            let targetIndex = currentIndex - metrics.columnCount
            guard targetIndex >= start else { return }
            selectItem(at: targetIndex)
        case .down:
            let targetIndex = currentIndex + metrics.columnCount
            guard targetIndex <= end else { return }
            selectItem(at: targetIndex)
        case .confirm, .back:
            break
        }
    }

    private func selectInitialItem(metrics: GridMetrics) {
        let start = min(page * metrics.pageSize, max(0, filteredItems.count - 1))
        guard filteredItems.indices.contains(start) else { return }
        selectItem(at: start)
    }

    private func selectItem(at index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        withAnimation(.spring(response: 0.20, dampingFraction: 0.86)) {
            selectedItemID = filteredItems[index].id
            selectedSlotIndex = index % GridMetrics.fixedPageSize
        }
    }

    private func activateSelectedItem() {
        guard let selectedItemID,
              let item = filteredItems.first(where: { $0.id == selectedItemID })
        else { return }

        switch item {
        case .app(let app):
            library.launch(app)
        case .folder(let folder):
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                openFolder(folder)
            }
        }
    }

    private func stabilizeSelectionOnCurrentPage(metrics: GridMetrics) {
        guard selectedItemID != nil || selectedSlotIndex != nil else { return }

        let start = page * metrics.pageSize
        let end = min(start + metrics.pageSize, filteredItems.count)
        guard start < end else {
            selectedItemID = nil
            selectedSlotIndex = nil
            return
        }

        if let selectedItemID,
           let selectedIndex = filteredItems.firstIndex(where: { $0.id == selectedItemID }),
           (start..<end).contains(selectedIndex) {
            selectedSlotIndex = selectedIndex - start
            return
        }

        let slot = min(max(selectedSlotIndex ?? 0, 0), end - start - 1)
        selectedSlotIndex = slot
        selectedItemID = filteredItems[start + slot].id
    }

    private func reconcileSelection() {
        guard selectedItemID != nil || selectedSlotIndex != nil else { return }

        if let selectedItemID, filteredItems.contains(where: { $0.id == selectedItemID }) {
            return
        }

        let pageSize = GridMetrics.fixedPageSize
        let start = page * pageSize
        let end = min(start + pageSize, filteredItems.count)
        guard start < end else {
            self.selectedItemID = nil
            selectedSlotIndex = nil
            return
        }

        let slot = min(max(selectedSlotIndex ?? 0, 0), end - start - 1)
        selectedSlotIndex = slot
        self.selectedItemID = filteredItems[start + slot].id
    }

    private func preferredIndexOnCurrentPage(metrics: GridMetrics, start: Int, end: Int) -> Int {
        let slot = min(max(selectedSlotIndex ?? 0, 0), end - start)
        return start + slot
    }

    private func rowStartSlot(metrics: GridMetrics, preferredSlot: Int) -> Int {
        (preferredSlot / metrics.columnCount) * metrics.columnCount
    }

    private func rowEndSlot(metrics: GridMetrics, preferredSlot: Int) -> Int {
        rowStartSlot(metrics: metrics, preferredSlot: preferredSlot) + metrics.columnCount - 1
    }

    private func clampPage(pageCount: Int) {
        let upperBound = max(0, pageCount - 1)
        let clamped = min(max(page, 0), upperBound)
        guard clamped != page else {
            if !isSearching {
                LauncherPageMemory.save(clamped)
            }
            return
        }

        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.24)) {
            page = clamped
        }
    }

    private func restorePageForCurrentQuery(pageCount: Int) {
        let rememberedPage = isSearching ? 0 : LauncherPageMemory.load()
        let upperBound = max(0, pageCount - 1)
        let target = min(max(rememberedPage, 0), upperBound)
        withAnimation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.28)) {
            page = target
        }
    }

    private func openFolder(_ folder: LaunchFolder) {
        canDismissByBackground = false
        openedFolder = folder
        Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            canDismissByBackground = true
        }
    }

    private func handleBlankTap() {
        guard draggingItemID == nil else { return }
        if isEditingApps {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                isEditingApps = false
            }
        } else if openedFolder != nil {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                openedFolder = nil
            }
        } else if canDismissByBackground {
            LauncherCommands.hide()
        }
    }

    private func beginEditingApps() {
        guard !isEditingApps else { return }
        searchFocused = false
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            isEditingApps = true
        }
    }

    private func endEditingApps() {
        guard isEditingApps else { return }
        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            isEditingApps = false
        }
    }

    private func confirmMoveToTrash(_ app: LaunchApp) {
        guard app.canMoveToTrash else { return }

        if app.needsFinderForDeletion {
            showFinderDeletionPrompt(for: app)
            return
        }

        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.moveToTrash.title", app.name)
        alert.informativeText = L10n.tr("alert.moveToTrash.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("button.moveToTrash"))
        alert.addButton(withTitle: L10n.tr("button.cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let didMoveToTrash = await library.moveToTrash(app)
            if !didMoveToTrash {
                showMoveToTrashFailure(for: app)
            }
        }
    }

    private func showFinderDeletionPrompt(for app: LaunchApp) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.finderDelete.title", app.name)
        alert.informativeText = L10n.tr("alert.finderDelete.message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L10n.tr("button.showInFinder"))
        alert.addButton(withTitle: L10n.tr("button.cancel"))

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([app.url])
    }

    private func showMoveToTrashFailure(for app: LaunchApp) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("alert.moveToTrashFailed.title", app.name)
        alert.informativeText = library.lastLaunchError ?? L10n.tr("alert.moveToTrashFailed.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("button.showInFinder"))
        alert.addButton(withTitle: L10n.tr("button.ok"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([app.url])
        }
    }

    private var currentOpenedFolder: LaunchFolder? {
        guard let openedFolder else { return nil }
        return library.items.compactMap { item -> LaunchFolder? in
            if case .folder(let folder) = item, folder.id == openedFolder.id {
                return folder
            }
            return nil
        }.first ?? openedFolder
    }

    private func scheduleDragCleanupIfNeeded() {
        dragCleanupTask?.cancel()
        guard draggingItemID != nil else { return }

        dragCleanupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)

            while !Task.isCancelled, draggingItemID != nil {
                let primaryButtonIsDown = (NSEvent.pressedMouseButtons & 1) == 1
                if !primaryButtonIsDown {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    if !Task.isCancelled, draggingItemID != nil {
                        draggingItemID = nil
                        draggingSourceFolderID = nil
                        dropTarget = nil
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }
}

private enum LauncherPageMemory {
    private static let key = "Launcheer.lastPage"

    static func load() -> Int {
        max(0, UserDefaults.standard.integer(forKey: key))
    }

    static func save(_ page: Int) {
        UserDefaults.standard.set(max(0, page), forKey: key)
    }
}

private enum ExternalNavigationCommand: Equatable {
    case left
    case right
    case up
    case down
    case confirm
    case back
}

private struct ExternalInputBridge: NSViewRepresentable {
    let onCommand: (ExternalNavigationCommand) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommand = onCommand
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommand: onCommand)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onCommand: (ExternalNavigationCommand) -> Void
        private var keyMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var heldDirection: ExternalNavigationCommand?
        private var repeatDelayTimer: Timer?
        private var repeatTimer: Timer?

        init(onCommand: @escaping (ExternalNavigationCommand) -> Void) {
            self.onCommand = onCommand
            super.init()
        }

        func start() {
            guard keyMonitor == nil else { return }

            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.handleKeyDown(event) else { return event }
                return nil
            }

            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.configureConnectedControllers()
                }
            })
            observers.append(center.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updateHeldDirection(nil)
                }
            })

            configureConnectedControllers()
            GCController.startWirelessControllerDiscovery(completionHandler: nil)
        }

        func stop() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            stopRepeatTimers()
            GCController.stopWirelessControllerDiscovery()
        }

        private func handleKeyDown(_ event: NSEvent) -> Bool {
            guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
            guard !Self.isTextInputActive(for: event) else { return false }

            switch event.keyCode {
            case 123:
                send(.left)
            case 124:
                send(.right)
            case 125:
                send(.down)
            case 126:
                send(.up)
            case 36, 76:
                send(.confirm)
            case 53:
                send(.back)
            default:
                return false
            }
            return true
        }

        private static func isTextInputActive(for event: NSEvent) -> Bool {
            guard let responder = event.window?.firstResponder ?? NSApp.keyWindow?.firstResponder else {
                return false
            }

            if responder is NSTextView || responder is NSTextField {
                return true
            }

            guard let view = responder as? NSView else { return false }
            var currentSuperview = view.superview
            while let superview = currentSuperview {
                if superview is NSTextField || superview is NSTextView {
                    return true
                }
                currentSuperview = superview.superview
            }
            return false
        }

        private func configure(_ controller: GCController) {
            if let gamepad = controller.extendedGamepad {
                gamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
                    Task { @MainActor in
                        self?.updateHeldDirection(Self.direction(x: xValue, y: yValue))
                    }
                }
                gamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
                    Task { @MainActor in
                        self?.updateHeldDirection(Self.direction(x: xValue, y: yValue))
                    }
                }
                gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in
                        self?.send(.confirm)
                    }
                }
                gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in
                        self?.send(.back)
                    }
                }
            }

            if let microGamepad = controller.microGamepad {
                microGamepad.reportsAbsoluteDpadValues = true
                microGamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
                    Task { @MainActor in
                        self?.updateHeldDirection(Self.direction(x: xValue, y: yValue))
                    }
                }
                microGamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in
                        self?.send(.confirm)
                    }
                }
                microGamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                    guard pressed else { return }
                    Task { @MainActor in
                        self?.send(.back)
                    }
                }
            }
        }

        private func configureConnectedControllers() {
            GCController.controllers().forEach(configure)
        }

        private static func direction(x: Float, y: Float) -> ExternalNavigationCommand? {
            let threshold: Float = 0.55
            guard abs(x) >= threshold || abs(y) >= threshold else { return nil }

            if abs(x) >= abs(y) {
                return x > 0 ? .right : .left
            }
            return y > 0 ? .up : .down
        }

        private func updateHeldDirection(_ direction: ExternalNavigationCommand?) {
            guard direction != heldDirection else { return }
            heldDirection = direction
            stopRepeatTimers()

            guard let direction else { return }
            send(direction)
            repeatDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.36, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.heldDirection == direction else { return }
                    self.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.165, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            guard let self, self.heldDirection == direction else {
                                self?.stopRepeatTimers()
                                return
                            }
                            self.send(direction)
                        }
                    }
                }
            }
        }

        private func send(_ command: ExternalNavigationCommand) {
            onCommand(command)
        }

        private func stopRepeatTimers() {
            repeatDelayTimer?.invalidate()
            repeatDelayTimer = nil
            repeatTimer?.invalidate()
            repeatTimer = nil
        }
    }
}

private struct PageStrip: View {
    let items: [LauncherItem]
    let metrics: GridMetrics
    let page: Int
    let pageCount: Int
    let width: CGFloat
    let dragEnabled: Bool
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    @Binding var dropTarget: LauncherDropTarget?
    let selectedItemID: String?
    let isEditingApps: Bool
    let pageDragOffset: CGFloat
    let launch: (LaunchApp) -> Void
    let openFolder: (LaunchFolder) -> Void
    let beginEditing: () -> Void
    let requestTrash: (LaunchApp) -> Void
    let blankTap: () -> Void
    let closeFolder: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<pageCount, id: \.self) { index in
                Group {
                    if abs(index - page) <= 1 {
                        AppGrid(
                            items: itemsForPage(index),
                            metrics: metrics,
                            dragEnabled: dragEnabled,
                            draggingItemID: $draggingItemID,
                            draggingSourceFolderID: $draggingSourceFolderID,
                            dropTarget: $dropTarget,
                            selectedItemID: selectedItemID,
                            isEditingApps: isEditingApps,
                            launch: launch,
                            openFolder: openFolder,
                            beginEditing: beginEditing,
                            requestTrash: requestTrash,
                            blankTap: blankTap,
                            closeFolder: closeFolder
                        )
                        .accessibilityHidden(index != page)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: width, alignment: .top)
            }
        }
        .frame(width: width, alignment: .leading)
        .offset(x: -CGFloat(page) * width + pageDragOffset)
        .animation(.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.32), value: page)
        .clipped()
    }

    private func itemsForPage(_ index: Int) -> [LauncherItem] {
        let start = index * metrics.pageSize
        let end = min(start + metrics.pageSize, items.count)
        guard start < end else { return [] }
        return Array(items[start..<end])
    }
}

private struct AppGrid: View {
    @EnvironmentObject private var library: AppLibrary

    let items: [LauncherItem]
    let metrics: GridMetrics
    let dragEnabled: Bool
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    @Binding var dropTarget: LauncherDropTarget?
    let selectedItemID: String?
    let isEditingApps: Bool
    let launch: (LaunchApp) -> Void
    let openFolder: (LaunchFolder) -> Void
    let beginEditing: () -> Void
    let requestTrash: (LaunchApp) -> Void
    let blankTap: () -> Void
    let closeFolder: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let itemDropTarget = dropTarget?.targetID == item.id ? dropTarget : nil
                LauncherTile(
                    item: item,
                    metrics: metrics,
                    dragEnabled: dragEnabled,
                    draggingItemID: $draggingItemID,
                    draggingSourceFolderID: $draggingSourceFolderID,
                    dropTarget: itemDropTarget,
                    isSelected: selectedItemID == item.id,
                    isEditingApps: isEditingApps,
                    launch: launch,
                    openFolder: openFolder,
                    beginEditing: beginEditing,
                    requestTrash: requestTrash
                )
                .onDrop(
                    of: [UTType.text],
                    delegate: LauncherItemDropDelegate(
                        target: item,
                        metrics: metrics,
                        draggingItemID: $draggingItemID,
                        draggingSourceFolderID: $draggingSourceFolderID,
                        dropTarget: $dropTarget,
                        closeFolder: closeFolder,
                        library: library
                    )
                )
                .position(tilePosition(for: index))
            }
        }
        .frame(width: metrics.gridWidth, height: metrics.gridHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(perform: blankTap)
        .onDrop(
            of: [UTType.text],
            delegate: AppGridDropDelegate(
                draggingItemID: $draggingItemID,
                draggingSourceFolderID: $draggingSourceFolderID,
                dropTarget: $dropTarget,
                closeFolder: closeFolder,
                library: library
            )
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: items.map(\.id))
    }

    private func tilePosition(for index: Int) -> CGPoint {
        let row = index / metrics.columnCount
        let column = index % metrics.columnCount
        let x = CGFloat(column) * (metrics.tileWidth + metrics.columnSpacing) + metrics.tileWidth / 2
        let y = CGFloat(row) * (metrics.tileHeight + metrics.rowSpacing) + metrics.tileHeight / 2
        return CGPoint(x: x, y: y)
    }
}

private struct GridMetrics: Equatable {
    static let fixedPageSize = 35

    let columnCount: Int
    let rowCount: Int
    let tileWidth: CGFloat
    let iconSize: CGFloat
    let rowSpacing: CGFloat
    let columnSpacing: CGFloat
    let tileHeight: CGFloat

    var pageSize: Int {
        columnCount * rowCount
    }

    var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(tileWidth), spacing: columnSpacing, alignment: .top),
            count: columnCount
        )
    }

    var gridWidth: CGFloat {
        CGFloat(columnCount) * tileWidth + CGFloat(max(0, columnCount - 1)) * columnSpacing
    }

    var gridHeight: CGFloat {
        CGFloat(rowCount) * tileHeight + CGFloat(max(0, rowCount - 1)) * rowSpacing
    }

    init(size: CGSize) {
        columnCount = 7
        rowCount = 5

        let baseWidth: CGFloat = 1512
        let baseHeight: CGFloat = 982
        let rawScale = min(max(size.width, 1) / baseWidth, max(size.height, 1) / baseHeight)
        let scale = min(1.22, max(0.88, sqrt(rawScale)))

        iconSize = (92 * scale).rounded(.toNearestOrAwayFromZero)
        tileWidth = (132 * scale).rounded(.toNearestOrAwayFromZero)
        tileHeight = (142 * scale).rounded(.toNearestOrAwayFromZero)

        let availableWidth = max(0, size.width - 220 * scale)
        let availableHeight = max(0, size.height - 214 * scale)
        let naturalColumnSpacing = (availableWidth - CGFloat(columnCount) * tileWidth) / CGFloat(columnCount - 1)
        let naturalRowSpacing = (availableHeight - CGFloat(rowCount) * tileHeight) / CGFloat(rowCount - 1)
        columnSpacing = max(18 * scale, min(58 * scale, naturalColumnSpacing))
        rowSpacing = max(14 * scale, min(34 * scale, naturalRowSpacing))
    }
}

private struct BackdropView: View {
    var body: some View {
        Color.clear
    }
}

private struct SearchBar: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))

            PlainSearchTextField(text: $text, placeholder: L10n.tr("search.placeholder"))
                .frame(height: 22)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
                .help(L10n.tr("help.clearSearch"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.white.opacity(0.18), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct PlainSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchNSTextField()
        field.delegate = context.coordinator
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: 16, weight: .medium)
        field.textColor = .white
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.72),
                .font: NSFont.systemFont(ofSize: 16, weight: .medium)
            ]
        )
        field.cell?.isScrollable = true
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text = field.stringValue
            configureEditor(for: field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            configureEditor(for: field)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            completions words: [String],
            forPartialWordRange charRange: NSRange,
            indexOfSelectedItem index: UnsafeMutablePointer<Int>
        ) -> [String] {
            []
        }

        private func configureEditor(for field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isGrammarCheckingEnabled = false
        }
    }
}

private final class SearchNSTextField: NSTextField {
    override func textDidEndEditing(_ notification: Notification) {
        guard let movement = notification.userInfo?["NSTextMovement"] as? Int else {
            super.textDidEndEditing(notification)
            return
        }

        if movement == NSReturnTextMovement {
            return
        }
        super.textDidEndEditing(notification)
    }
}

private struct LauncherTile: View {
    let item: LauncherItem
    let metrics: GridMetrics
    let dragEnabled: Bool
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    let dropTarget: LauncherDropTarget?
    let isSelected: Bool
    let isEditingApps: Bool
    let launch: (LaunchApp) -> Void
    let openFolder: (LaunchFolder) -> Void
    let beginEditing: () -> Void
    let requestTrash: (LaunchApp) -> Void
    @State private var hovering = false
    @State private var isPointerInsideIcon = false
    @State private var isPointerInsideTile = false

    var body: some View {
        Button(action: activate) {
            VStack(spacing: 8) {
                ZStack {
                    icon
                        .frame(width: metrics.iconSize, height: metrics.iconSize)
                        .shadow(color: .black.opacity(0.30), radius: 11, y: 5)

                    selectionOutline
                }
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .contentShape(RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous))
                .onHover { inside in
                    isPointerInsideIcon = inside
                    updateHoverState()
                }
                .overlay(alignment: .topTrailing) {
                    if isEditingApps, case .app(let app) = item, app.canMoveToTrash {
                        EditModeDeleteButton {
                            requestTrash(app)
                        }
                        .offset(x: -2, y: 2)
                    }
                }

                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: metrics.tileWidth - 8, height: 34, alignment: .top)
                    .shadow(color: .black.opacity(0.72), radius: 3, y: 1)
            }
            .frame(width: metrics.tileWidth, height: metrics.tileHeight, alignment: .top)
            .contentShape(Rectangle())
            .scaleEffect(hovering && !isEditingApps ? 1.045 : 1)
            .animation(.spring(response: 0.20, dampingFraction: 0.82), value: hovering)
            .modifier(WiggleEffect(isActive: isEditingApps, phaseSeed: item.id))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.52, maximumDistance: 8)
                .onEnded { _ in beginEditing() }
        )
        .onHover { inside in
            isPointerInsideTile = inside
            if !inside {
                isPointerInsideIcon = false
            }
            updateHoverState()
        }
        .help(item.name)
        .opacity(draggingItemID == item.id ? 0 : 1)
        .if(dragEnabled) { view in
            view.onDrag {
                draggingItemID = item.id
                draggingSourceFolderID = nil
                return NSItemProvider(object: item.id as NSString)
            }
        }
        .overlay {
            DropPlaceholder(intent: dropTarget?.intent, metrics: metrics)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch item {
        case .app(let app):
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .folder(let folder):
            FolderIcon(folder: folder, size: metrics.iconSize)
        }
    }

    @ViewBuilder
    private var selectionOutline: some View {
        if isSelected && draggingItemID != item.id {
            RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                .strokeBorder(.black.opacity(0.50), lineWidth: 2)
                .frame(width: selectionRingSize, height: selectionRingSize)
                .allowsHitTesting(false)
        }
    }

    private var selectionRingSize: CGFloat {
        switch item {
        case .app:
            return metrics.iconSize
        case .folder:
            return metrics.iconSize * FolderIcon.visualSizeRatio
        }
    }

    private var selectionCornerRadius: CGFloat {
        selectionRingSize * visualCornerRatio
    }

    private var visualCornerRatio: CGFloat {
        switch item {
        case .app:
            return 0.2237
        case .folder:
            return FolderIcon.cornerRatio
        }
    }

    private func activate() {
        guard !isEditingApps else { return }

        switch item {
        case .app(let app):
            launch(app)
        case .folder(let folder):
            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                openFolder(folder)
            }
        }
    }

    private func updateHoverState() {
        hovering = isPointerInsideTile && isPointerInsideIcon
    }
}

private struct FolderIcon: View {
    static let visualSizeRatio: CGFloat = 0.78
    static let cornerRatio: CGFloat = 0.22

    let folder: LaunchFolder
    let size: CGFloat

    private var folderSize: CGFloat {
        size * Self.visualSizeRatio
    }

    private var miniIconSize: CGFloat {
        folderSize * 0.24
    }

    private var miniIconSpacing: CGFloat {
        folderSize * 0.08
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: folderSize * Self.cornerRatio, style: .continuous)
                .fill(.white.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: folderSize * Self.cornerRatio, style: .continuous)
                        .stroke(.white.opacity(0.24), lineWidth: 1)
                }
                .frame(width: folderSize, height: folderSize)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(miniIconSize), spacing: miniIconSpacing), count: 3),
                spacing: miniIconSpacing
            ) {
                ForEach(Array(folder.apps.prefix(9))) { app in
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: miniIconSize, height: miniIconSize)
                }
            }
            .frame(width: folderSize * 0.72, height: folderSize * 0.72, alignment: .center)
        }
        .frame(width: size, height: size)
    }
}

private struct EditModeDeleteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.68))
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.72), lineWidth: 1)
                    }

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            .shadow(color: .black.opacity(0.28), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .help(L10n.tr("help.moveToTrash"))
    }
}

private struct WiggleEffect: ViewModifier {
    let isActive: Bool
    let phaseSeed: String
    @State private var wiggle = false

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(isActive ? (wiggle ? 1.15 : -1.15) : 0))
            .offset(
                x: isActive ? (wiggle ? 0.7 : -0.7) : 0,
                y: isActive ? (wiggle ? -0.3 : 0.3) : 0
            )
            .animation(
                isActive
                    ? .easeInOut(duration: 0.115).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.12),
                value: wiggle
            )
            .onAppear(perform: updateWiggle)
            .onChange(of: isActive) {
                updateWiggle()
            }
    }

    private var phaseDelay: Double {
        Double(abs(phaseSeed.hashValue % 7)) * 0.018
    }

    private func updateWiggle() {
        guard isActive else {
            wiggle = false
            return
        }

        wiggle = false
        DispatchQueue.main.asyncAfter(deadline: .now() + phaseDelay) {
            if isActive {
                wiggle = true
            }
        }
    }
}

private struct DropPlaceholder: View {
    let intent: LauncherDropIntent?
    let metrics: GridMetrics

    var body: some View {
        ZStack {
            switch intent {
            case .before:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.86))
                    .frame(width: 4, height: metrics.iconSize + 30)
                    .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 4)
            case .after:
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(.white.opacity(0.86))
                    .frame(width: 4, height: metrics.iconSize + 30)
                    .shadow(color: .black.opacity(0.30), radius: 4, y: 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            case .group:
                ZStack {
                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous)
                        .fill(.white.opacity(0.035))

                    RoundedRectangle(cornerRadius: metrics.iconSize * 0.22, style: .continuous)
                        .inset(by: 2)
                        .stroke(
                            .white.opacity(0.54),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [6, 5])
                        )
                }
                .frame(width: metrics.iconSize, height: metrics.iconSize)
                .shadow(color: .black.opacity(0.14), radius: 5, y: 2)
                .frame(width: metrics.tileWidth, height: metrics.tileHeight, alignment: .top)
            case nil:
                EmptyView()
            }
        }
        .animation(.spring(response: 0.18, dampingFraction: 0.84), value: intent)
    }
}

private struct FolderFullScreenView: View {
    @EnvironmentObject private var library: AppLibrary

    let folder: LaunchFolder
    let metrics: GridMetrics
    let availableSize: CGSize
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    @Binding var dropTarget: LauncherDropTarget?
    let isEditingApps: Bool
    let launch: (LaunchApp) -> Void
    let beginEditing: () -> Void
    let endEditing: () -> Void
    let requestTrash: (LaunchApp) -> Void
    let close: () -> Void
    let closeForDragOut: () -> Void
    @State private var title = ""
    @State private var outsideDropTargeted = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if isEditingApps {
                        endEditing()
                    } else {
                        close()
                    }
                }
                .onDrop(of: [UTType.text], isTargeted: $outsideDropTargeted) { _ in
                    false
                }

            VStack(spacing: 24) {
                titleField
                panel
            }
            .padding(.top, topInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: outsideDropTargeted) {
            guard outsideDropTargeted, draggingSourceFolderID == folder.id else { return }
            withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
                closeForDragOut()
            }
        }
        .onAppear {
            title = folder.name
        }
        .onChange(of: folder.name) {
            if !titleFocused {
                title = folder.name
            }
        }
    }

    private var titleField: some View {
        TextField(L10n.tr("folder.placeholder"), text: $title)
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .frame(width: min(panelWidth * 0.48, 420), height: 38)
            .focused($titleFocused)
            .onSubmit(saveTitle)
            .onChange(of: titleFocused) {
                if !titleFocused {
                    saveTitle()
                }
            }
            .shadow(color: .black.opacity(0.56), radius: 4, y: 1)
    }

    private var panel: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .fill(.white.opacity(0.10))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 28, y: 14)

            folderContent
                .padding(.top, panelTopPadding)
        }
        .frame(width: panelWidth, height: panelHeight)
        .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
        .onTapGesture {
            if isEditingApps {
                endEditing()
            }
        }
        .onDrop(
            of: [UTType.text],
            delegate: FolderInteriorDropDelegate(
                folderID: folder.id,
                draggingItemID: $draggingItemID,
                draggingSourceFolderID: $draggingSourceFolderID,
                dropTarget: $dropTarget
            )
        )
    }

    private var folderContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: metrics.rowSpacing * 1.12) {
                ForEach(folder.apps) { app in
                    Button {
                        guard !isEditingApps else { return }
                        launch(app)
                    } label: {
                        VStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: metrics.iconSize, height: metrics.iconSize)
                                .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
                                .overlay(alignment: .topTrailing) {
                                    if isEditingApps, app.canMoveToTrash {
                                        EditModeDeleteButton {
                                            requestTrash(app)
                                        }
                                        .offset(x: -2, y: 2)
                                    }
                                }

                            Text(app.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: metrics.tileWidth - 10, height: 34, alignment: .top)
                                .shadow(color: .black.opacity(0.70), radius: 3, y: 1)
                        }
                        .frame(width: metrics.tileWidth, height: metrics.tileHeight, alignment: .top)
                        .modifier(WiggleEffect(isActive: isEditingApps, phaseSeed: app.id))
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.52, maximumDistance: 8)
                            .onEnded { _ in beginEditing() }
                    )
                    .help(app.name)
                    .opacity(draggingItemID == app.id ? 0 : 1)
                    .if(!isEditingApps) { view in
                        view.onDrag {
                            draggingItemID = app.id
                            draggingSourceFolderID = folder.id
                            dropTarget = nil
                            return NSItemProvider(object: app.id as NSString)
                        }
                    }
                }
            }
            .frame(width: contentWidth, alignment: .topLeading)
            .padding(.bottom, panelTopPadding)
        }
        .frame(width: contentWidth, height: max(0, panelHeight - panelTopPadding), alignment: .topLeading)
    }

    private var columnCount: Int {
        min(metrics.columnCount, max(1, maximumColumnCount))
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(metrics.tileWidth), spacing: metrics.columnSpacing, alignment: .top),
            count: columnCount
        )
    }

    private var topInset: CGFloat {
        max(72, min(126, availableSize.height * 0.11))
    }

    private var panelWidth: CGFloat {
        let preferred = max(metrics.gridWidth + metrics.tileWidth * 0.92, 860)
        return min(availableSize.width * 0.88, preferred)
    }

    private var panelHeight: CGFloat {
        let preferred = availableSize.height * 0.70
        let contentRows = CGFloat(max(1, Int(ceil(Double(folder.apps.count) / Double(columnCount)))))
        let contentHeight = contentRows * metrics.tileHeight + max(0, contentRows - 1) * metrics.rowSpacing * 1.12
        let minimum = min(availableSize.height * 0.70, max(360, contentHeight + panelTopPadding * 2))
        return min(max(preferred, minimum), max(360, availableSize.height - topInset - 92))
    }

    private var panelCornerRadius: CGFloat {
        max(28, metrics.iconSize * 0.36)
    }

    private var panelTopPadding: CGFloat {
        max(52, metrics.iconSize * 0.68)
    }

    private var panelHorizontalPadding: CGFloat {
        max(56, metrics.tileWidth * 0.82)
    }

    private var maximumColumnCount: Int {
        let availableContentWidth = max(metrics.tileWidth, panelWidth - panelHorizontalPadding * 2)
        let fullTileWidth = metrics.tileWidth + metrics.columnSpacing
        return max(1, Int((availableContentWidth + metrics.columnSpacing) / fullTileWidth))
    }

    private var contentWidth: CGFloat {
        max(
            metrics.tileWidth,
            panelWidth - panelHorizontalPadding * 2
        )
    }

    private func saveTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = folder.name
            return
        }
        if trimmed != folder.name {
            library.renameFolder(folder.id, to: trimmed)
        }
    }
}

private struct FolderInteriorDropDelegate: DropDelegate {
    let folderID: String
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    @Binding var dropTarget: LauncherDropTarget?

    func validateDrop(info: DropInfo) -> Bool {
        draggingItemID != nil && draggingSourceFolderID == folderID
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        draggingItemID = nil
        draggingSourceFolderID = nil
        dropTarget = nil
        return true
    }
}

private enum LauncherDropIntent: Equatable {
    case before
    case after
    case group
}

private struct LauncherDropTarget: Equatable {
    let targetID: String
    let intent: LauncherDropIntent
}

private struct AppGridDropDelegate: DropDelegate {
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    @Binding var dropTarget: LauncherDropTarget?
    let closeFolder: () -> Void
    let library: AppLibrary

    func validateDrop(info: DropInfo) -> Bool {
        draggingItemID != nil && draggingSourceFolderID != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .move) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingItemID, let draggingSourceFolderID else { return false }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            library.ungroupApp(draggingItemID, from: draggingSourceFolderID)
            closeFolder()
        }

        self.draggingItemID = nil
        self.draggingSourceFolderID = nil
        dropTarget = nil
        return true
    }

    func dropExited(info: DropInfo) {
        dropTarget = nil
    }
}

private struct LauncherItemDropDelegate: DropDelegate {
    let target: LauncherItem
    let metrics: GridMetrics
    @Binding var draggingItemID: String?
    @Binding var draggingSourceFolderID: String?
    @Binding var dropTarget: LauncherDropTarget?
    let closeFolder: () -> Void
    let library: AppLibrary

    func validateDrop(info: DropInfo) -> Bool {
        draggingItemID != nil && draggingItemID != target.id
    }

    func dropEntered(info: DropInfo) {
        updateDropTarget(for: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropTarget(for: info.location)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let draggingItemID, draggingItemID != target.id else { return false }
        let intent = dropIntent(at: info.location)

        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            if let draggingSourceFolderID {
                if intent == .group {
                    library.groupAppFromFolder(draggingItemID, from: draggingSourceFolderID, on: target.id)
                } else {
                    let placement: LayoutPlacement = intent == .before ? .before : .after
                    library.moveAppFromFolder(draggingItemID, from: draggingSourceFolderID, relativeTo: target.id, placement: placement)
                }
                closeFolder()
            } else if intent == .group {
                library.groupItem(draggingItemID, on: target.id)
            } else {
                let placement: LayoutPlacement = intent == .before ? .before : .after
                library.moveItem(draggingItemID, relativeTo: target.id, placement: placement)
            }
        }

        self.draggingItemID = nil
        draggingSourceFolderID = nil
        dropTarget = nil
        return true
    }

    func dropExited(info: DropInfo) {
        if dropTarget?.targetID == target.id {
            dropTarget = nil
        }
    }

    private func updateDropTarget(for location: CGPoint) {
        guard draggingItemID != nil, draggingItemID != target.id else {
            dropTarget = nil
            return
        }
        dropTarget = LauncherDropTarget(targetID: target.id, intent: dropIntent(at: location))
    }

    private func dropIntent(at location: CGPoint) -> LauncherDropIntent {
        if shouldGroup(at: location) {
            return .group
        }
        return location.x < metrics.tileWidth / 2 ? .before : .after
    }

    private func shouldGroup(at location: CGPoint) -> Bool {
        let iconInset = (metrics.tileWidth - metrics.iconSize) / 2
        let iconRect = CGRect(
            x: iconInset - 10,
            y: 0,
            width: metrics.iconSize + 20,
            height: metrics.iconSize + 22
        )
        return iconRect.contains(location)
    }
}

private struct PageControls: View {
    let page: Int
    let pageCount: Int
    let previous: () -> Void
    let next: () -> Void
    let select: (Int) -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 16) {
            Button(action: previous) {
                Image(systemName: "chevron.left")
            }
            .disabled(page == 0)
            .buttonStyle(PageButtonStyle())
            .help(L10n.tr("help.previousPage"))
            .opacity(showButtons ? 1 : 0)
            .allowsHitTesting(showButtons)

            HStack(spacing: 7) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Button {
                        select(index)
                    } label: {
                        Circle()
                            .fill(index == page ? .white : .white.opacity(0.34))
                            .frame(width: index == page ? 7 : 6, height: index == page ? 7 : 6)
                            .frame(width: 14, height: 18)
                    }
                    .buttonStyle(.plain)
                    .disabled(index == page)
                    .help(L10n.tr("help.pageNumber", index + 1))
                }
            }
            .frame(minWidth: 64)

            Button(action: next) {
                Image(systemName: "chevron.right")
            }
            .disabled(page >= pageCount - 1)
            .buttonStyle(PageButtonStyle())
            .help(L10n.tr("help.nextPage"))
            .opacity(showButtons ? 1 : 0)
            .allowsHitTesting(showButtons)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .animation(.easeOut(duration: 0.16), value: showButtons)
    }

    private var showButtons: Bool {
        isHovering && pageCount > 1
    }
}

private struct PageButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.56 : 0.9))
            .frame(width: 28, height: 28)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.10), in: Circle())
    }
}

private struct HeaderControls: View {
    let reload: () -> Void

    var body: some View {
        Button(action: reload) {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(HeaderButtonStyle())
        .help(L10n.tr("help.reloadApplications"))
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.58 : 0.9))
            .frame(width: 30, height: 30)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.12), in: Circle())
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct EmptyState: View {
    let query: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "app.dashed")
                .font(.system(size: 42, weight: .regular))
                .foregroundStyle(.white.opacity(0.7))

            Text(query.isEmpty ? L10n.tr("empty.noApplications") : L10n.tr("empty.noMatches"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
