#if canImport(UIKit)
  import UIKit

  @MainActor
  final class AnalyticsLifecycle {
    private let analytics: Analytics
    private var observations: [NSObjectProtocol] = []
    private var active = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    init(analytics: Analytics) { self.analytics = analytics }
    func start() async {
      observe(UIApplication.didBecomeActiveNotification) { [weak self] in
        guard let self, !self.active else { return }
        self.active = true
        Task {
          await self.analytics.track("app_active")
          await self.analytics.flush()
        }
      }
      observe(UIApplication.willResignActiveNotification) { [weak self] in self?.active = false }
      observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.background() }
      if UIApplication.shared.applicationState == .active {
        active = true
        await analytics.track("app_active")
      }
    }
    private func observe(
      _ name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void
    ) {
      observations.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
          Task { @MainActor in action() }
        })
    }
    private func background() {
      active = false
      guard backgroundTask == .invalid else { return }
      backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AppbaseAnalytics.flush")
      { [weak self] in
        Task { @MainActor in self?.endBackground() }
      }
      Task { [weak self] in
        guard let self else { return }
        await self.analytics.flush()
        self.endBackground()
      }
    }
    private func endBackground() {
      guard backgroundTask != .invalid else { return }
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
    func stop() {
      for token in observations { NotificationCenter.default.removeObserver(token) }
      observations = []
      endBackground()
    }
  }
#endif
