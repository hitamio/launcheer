import AppKit
import SwiftUI

struct TrackpadPageMonitor: NSViewRepresentable {
    let canGoPrevious: Bool
    let canGoNext: Bool
    let maxInteractiveOffset: CGFloat
    let pageTurnDistanceThreshold: CGFloat
    let dragChanged: (CGFloat) -> Void
    let dragEnded: () -> Void
    let previous: () -> Void
    let next: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.update(
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext,
            maxInteractiveOffset: maxInteractiveOffset,
            pageTurnDistanceThreshold: pageTurnDistanceThreshold,
            dragChanged: dragChanged,
            dragEnded: dragEnded,
            previous: previous,
            next: next
        )
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            canGoPrevious: canGoPrevious,
            canGoNext: canGoNext,
            maxInteractiveOffset: maxInteractiveOffset,
            pageTurnDistanceThreshold: pageTurnDistanceThreshold,
            dragChanged: dragChanged,
            dragEnded: dragEnded,
            previous: previous,
            next: next
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?

        private var monitor: Any?
        private var horizontalDelta: CGFloat = 0
        private var gestureStartTimestamp: TimeInterval?
        private var lastEventTimestamp: TimeInterval?
        private var recentVelocity: CGFloat = 0
        private var resetWorkItem: DispatchWorkItem?
        private var offsetFlushWorkItem: DispatchWorkItem?
        private var pendingOffset: CGFloat?
        private var lastEmittedOffset: CGFloat = 0
        private var lastOffsetEmitTime: CFTimeInterval = 0
        private var lastPageTurn = Date.distantPast
        private var canGoPrevious = false
        private var canGoNext = false
        private var maxInteractiveOffset: CGFloat = 46
        private var pageTurnDistanceThreshold: CGFloat = 36
        private var dragChanged: (CGFloat) -> Void = { _ in }
        private var dragEnded: () -> Void = {}
        private var previous: () -> Void = {}
        private var next: () -> Void = {}

        func update(
            canGoPrevious: Bool,
            canGoNext: Bool,
            maxInteractiveOffset: CGFloat,
            pageTurnDistanceThreshold: CGFloat,
            dragChanged: @escaping (CGFloat) -> Void,
            dragEnded: @escaping () -> Void,
            previous: @escaping () -> Void,
            next: @escaping () -> Void
        ) {
            self.canGoPrevious = canGoPrevious
            self.canGoNext = canGoNext
            self.maxInteractiveOffset = maxInteractiveOffset
            self.pageTurnDistanceThreshold = pageTurnDistanceThreshold
            self.dragChanged = dragChanged
            self.dragEnded = dragEnded
            self.previous = previous
            self.next = next
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            resetWorkItem?.cancel()
            resetWorkItem = nil
            offsetFlushWorkItem?.cancel()
            offsetFlushWorkItem = nil
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard event.window === view?.window else { return }

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                resetGesture()
                gestureStartTimestamp = event.timestamp
                emitDragOffset(0, immediate: true)
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                finishGesture()
                return
            }

            guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
            guard event.momentumPhase.isEmpty else {
                resetAfterInactiveInterval()
                return
            }

            updateVelocity(with: event)
            horizontalDelta += event.scrollingDeltaX

            let canMoveInDirection = horizontalDelta > 0 ? canGoPrevious : canGoNext
            let resistanceScale: CGFloat = canMoveInDirection ? 1 : 0.28
            emitDragOffset(resistedOffset(for: horizontalDelta) * resistanceScale)
            resetAfterInactiveInterval()
        }

        private func finishGesture() {
            resetWorkItem?.cancel()
            resetWorkItem = nil

            defer {
                resetGesture()
                emitDragOffset(0, immediate: true)
                dragEnded()
            }

            let distanceThreshold = pageTurnDistanceThreshold
            let velocityThreshold: CGFloat = 620
            let maxFlickDuration: TimeInterval = 0.58
            let gestureDuration = (lastEventTimestamp ?? gestureStartTimestamp ?? 0) - (gestureStartTimestamp ?? 0)
            guard abs(horizontalDelta) >= distanceThreshold else { return }
            guard abs(recentVelocity) >= velocityThreshold else { return }
            guard gestureDuration <= maxFlickDuration else { return }
            guard horizontalDelta * recentVelocity > 0 else { return }
            guard Date().timeIntervalSince(lastPageTurn) > 0.34 else { return }

            if horizontalDelta > 0, canGoPrevious {
                lastPageTurn = Date()
                previous()
            } else if horizontalDelta < 0, canGoNext {
                lastPageTurn = Date()
                next()
            }
        }

        private func resetAfterInactiveInterval() {
            resetWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.horizontalDelta != 0 else { return }
                    self.finishGesture()
                }
            }
            resetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: workItem)
        }

        private func emitDragOffset(_ offset: CGFloat, immediate: Bool = false) {
            pendingOffset = offset

            if immediate {
                offsetFlushWorkItem?.cancel()
                offsetFlushWorkItem = nil
                flushPendingOffset()
                return
            }

            let now = CACurrentMediaTime()
            let frameInterval: CFTimeInterval = 1.0 / 90.0
            let elapsed = now - lastOffsetEmitTime

            if elapsed >= frameInterval {
                flushPendingOffset()
                return
            }

            guard offsetFlushWorkItem == nil else { return }
            let delay = frameInterval - elapsed
            let workItem = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.flushPendingOffset()
                }
            }
            offsetFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        private func flushPendingOffset() {
            offsetFlushWorkItem?.cancel()
            offsetFlushWorkItem = nil

            guard let pendingOffset else { return }
            self.pendingOffset = nil

            guard abs(pendingOffset - lastEmittedOffset) >= 0.5 || pendingOffset == 0 else { return }
            lastEmittedOffset = pendingOffset
            lastOffsetEmitTime = CACurrentMediaTime()
            dragChanged(pendingOffset)
        }

        private func updateVelocity(with event: NSEvent) {
            defer {
                lastEventTimestamp = event.timestamp
            }

            guard let lastEventTimestamp else { return }
            let interval = max(0.001, event.timestamp - lastEventTimestamp)
            let velocity = event.scrollingDeltaX / CGFloat(interval)
            recentVelocity = recentVelocity == 0 ? velocity : (recentVelocity * 0.35 + velocity * 0.65)
        }

        private func resistedOffset(for delta: CGFloat) -> CGFloat {
            guard maxInteractiveOffset > 0 else { return 0 }
            let magnitude = maxInteractiveOffset * (1 - exp(-abs(delta) / maxInteractiveOffset))
            return (delta >= 0 ? 1 : -1) * min(maxInteractiveOffset, magnitude)
        }

        private func resetGesture() {
            resetWorkItem?.cancel()
            resetWorkItem = nil
            offsetFlushWorkItem?.cancel()
            offsetFlushWorkItem = nil
            pendingOffset = nil
            lastEmittedOffset = 0
            horizontalDelta = 0
            gestureStartTimestamp = nil
            recentVelocity = 0
            lastEventTimestamp = nil
        }
    }
}
