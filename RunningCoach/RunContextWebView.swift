import SwiftUI
import UIKit
import UserNotifications
import WebKit

final class RunContextWKWebView: WKWebView {
    override var inputAccessoryView: UIView? {
        nil
    }
}

private struct RunContextNotificationRequest {
    let id: String
    let title: String
    let body: String
    let date: Date

    nonisolated init?(payload: [String: Any]) {
        guard let id = payload["id"] as? String,
              let title = payload["title"] as? String,
              let body = payload["body"] as? String,
              let dateIso = payload["dateIso"] as? String,
              let date = ISO8601DateFormatter().date(from: dateIso) else {
            return nil
        }
        self.id = id
        self.title = title
        self.body = body
        self.date = date
    }
}

private struct RunContextNotificationSettings {
    let allEnabled: Bool
    let healthKitNewRun: Bool

    init(payload: [String: Any]) {
        allEnabled = payload["allEnabled"] as? Bool ?? false
        healthKitNewRun = payload["healthKitNewRun"] as? Bool ?? true
    }
}

private final class RunContextNotificationManager {
    private let notificationPrefix = "pacelab-"
    private let settingsKey = "pacelab.notificationSettings"
    private let pendingHealthKitNotificationWindow: TimeInterval = 10 * 60
    private var pendingHealthKitDetectedAt: Date?

    func updateSettings(_ settings: RunContextNotificationSettings) {
        UserDefaults.standard.set([
            "allEnabled": settings.allEnabled,
            "healthKitNewRun": settings.healthKitNewRun
        ], forKey: settingsKey)
        print("[RunContext Notifications] settings updated all=\(settings.allEnabled) healthKit=\(settings.healthKitNewRun)")
        if UIApplication.shared.applicationState == .active {
            pendingHealthKitDetectedAt = nil
            print("[RunContext Notifications] pending HealthKit detected notification discarded while app active")
            return
        }
        showPendingHealthKitDetectedNotificationIfNeeded(settings: settings)
    }

    func syncScheduledNotifications(enabled: Bool, requests: [RunContextNotificationRequest]) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { [notificationPrefix] pending in
            let identifiers = pending
                .map(\.identifier)
                .filter { $0.hasPrefix(notificationPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)

            guard enabled else { return }
            self.requestAuthorization { granted in
                print("[RunContext Notifications] authorization \(granted ? "granted" : "not granted"), scheduled=\(requests.count)")
                guard granted else { return }
                requests.forEach { self.schedule($0) }
            }
        }
    }

    func showImmediateNotification(id: String, title: String, body: String) {
        requestAuthorization { [weak self] granted in
            print("[RunContext Notifications] immediate authorization \(granted ? "granted" : "not granted")")
            guard granted, let self else { return }
            let content = self.content(title: title, body: body)
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
            let request = UNNotificationRequest(identifier: self.notificationPrefix + id, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func showHealthKitDetectedNotificationIfEnabled() {
        let settings = loadSettings()
        guard settings.allEnabled, settings.healthKitNewRun else {
            print("[RunContext Notifications] HealthKit detected notification skipped settings all=\(settings.allEnabled) healthKit=\(settings.healthKitNewRun)")
            if !settings.allEnabled, settings.healthKitNewRun {
                pendingHealthKitDetectedAt = Date()
                print("[RunContext Notifications] HealthKit detected notification pending until web settings sync")
            }
            return
        }
        showHealthKitDetectedNotification()
    }

    private func showPendingHealthKitDetectedNotificationIfNeeded(settings: RunContextNotificationSettings) {
        guard settings.allEnabled, settings.healthKitNewRun, let detectedAt = pendingHealthKitDetectedAt else { return }
        pendingHealthKitDetectedAt = nil
        guard Date().timeIntervalSince(detectedAt) <= pendingHealthKitNotificationWindow else {
            print("[RunContext Notifications] pending HealthKit detected notification expired")
            return
        }
        print("[RunContext Notifications] showing pending HealthKit detected notification")
        showHealthKitDetectedNotification()
    }

    private func showHealthKitDetectedNotification() {
        showImmediateNotification(
            id: "healthkit-detected-\(Date().timeIntervalSince1970)",
            title: "새 러닝 기록이 감지됐습니다",
            body: "PaceLAB을 열면 HealthKit 기록을 동기화합니다."
        )
    }

    private func schedule(_ request: RunContextNotificationRequest) {
        let interval = request.date.timeIntervalSinceNow
        guard interval > 1 else { return }
        let content = content(title: request.title, body: request.body)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let notification = UNNotificationRequest(identifier: notificationPrefix + request.id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(notification)
    }

    private func content(title: String, body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "pacelab-training"
        return content
    }

    private func requestAuthorization(completion: @escaping (Bool) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                completion(true)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    completion(granted)
                }
            case .denied:
                print("[RunContext Notifications] authorization denied in iOS Settings")
                completion(false)
            @unknown default:
                print("[RunContext Notifications] authorization unknown status")
                completion(false)
            }
        }
    }

    private func loadSettings() -> RunContextNotificationSettings {
        let payload = UserDefaults.standard.dictionary(forKey: settingsKey) ?? [:]
        return RunContextNotificationSettings(payload: payload)
    }
}

struct RunContextWebView: UIViewRepresentable {
    var onReady: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady)
    }

    func makeUIView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "runContextHealthKit")
        contentController.add(context.coordinator, name: "runContextWeatherKit")
        contentController.add(context.coordinator, name: "runContextHaptics")
        contentController.add(context.coordinator, name: "runContextNotifications")
        contentController.add(context.coordinator, name: "runContextLog")
        contentController.addUserScript(WKUserScript(
            source: """
            window.addEventListener('error', function(event) {
              window.webkit.messageHandlers.runContextLog.postMessage('JS error: ' + event.message + ' at ' + event.filename + ':' + event.lineno);
            });
            window.addEventListener('unhandledrejection', function(event) {
              window.webkit.messageHandlers.runContextLog.postMessage('JS rejection: ' + String(event.reason));
            });
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController

        let webView = RunContextWKWebView(frame: .zero, configuration: configuration)
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = RunContextColors.nativeBackground
        webView.scrollView.backgroundColor = RunContextColors.nativeBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        loadWebApp(in: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.backgroundColor = RunContextColors.nativeBackground
        webView.scrollView.backgroundColor = RunContextColors.nativeBackground
    }

    private func loadWebApp(in webView: WKWebView) {
        webView.load(URLRequest(url: webAppURL))
    }

    private var webAppURL: URL {
        URL(string: "https://lena0611.github.io/RunningCoach/#/")!
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UNUserNotificationCenterDelegate {
        weak var webView: WKWebView?
        private let importer = HealthKitRunImporter()
        private let weatherImporter = OpenMeteoWeatherImporter()
        private let notificationManager = RunContextNotificationManager()
        private let onReady: () -> Void
        private let minimumSplashDuration: TimeInterval = 1.5
        private let startedAt = Date()
        private var didSignalReady = false

        init(onReady: @escaping () -> Void) {
            self.onReady = onReady
            super.init()
            UNUserNotificationCenter.current().delegate = self
            importer.startRunningWorkoutBackgroundDelivery { [weak self] in
                DispatchQueue.main.async {
                    self?.handleBackgroundHealthKitChange()
                }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "runContextLog" {
                print("[RunContext WebView]", message.body)
                return
            }

            if message.name == "runContextWeatherKit" {
                handleWeatherMessage(message)
                return
            }

            if message.name == "runContextHaptics" {
                handleHapticsMessage(message)
                return
            }

            if message.name == "runContextNotifications" {
                handleNotificationMessage(message)
                return
            }

            guard message.name == "runContextHealthKit" else { return }
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                sendError("지원하지 않는 HealthKit 요청입니다.")
                return
            }

            switch type {
            case "requestRecentRunningWorkouts":
                let days = body["days"] as? Int ?? 14
                print("[RunContext HealthKit] requestRecentRunningWorkouts days=\(days)")
                importer.fetchRecentRunningWorkouts(days: days) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let candidates):
                            print("[RunContext HealthKit] fetched candidates=\(candidates.count)")
                            self?.sendRuns(candidates)
                        case .failure(let error):
                            print("[RunContext HealthKit] failed:", error.localizedDescription)
                            self?.sendError(error.localizedDescription)
                        }
                    }
                }

            case "requestRunningWorkoutByExternalId":
                let externalId = body["externalId"] as? String
                let date = body["date"] as? String
                let distanceKm = numberValue(body["distanceKm"])
                let durationSec = numberValue(body["durationSec"])
                let request = HealthKitRunRefreshRequest(
                    externalId: externalId?.isEmpty == false ? externalId : nil,
                    date: date,
                    distanceKm: distanceKm,
                    durationSec: durationSec
                )

                if request.externalId == nil && (request.date == nil || request.distanceKm == nil) {
                    sendRunUpdateError(externalId: nil, message: "HealthKit 갱신에 필요한 세션 식별 정보가 부족합니다.")
                    return
                }

                print("[RunContext HealthKit] requestRunningWorkoutByExternalId externalId=\(request.externalId ?? "fallback") date=\(request.date ?? "-")")
                importer.fetchRunningWorkout(request: request) { [weak self] result in
                    DispatchQueue.main.async {
                        switch result {
                        case .success(let candidate):
                            print("[RunContext HealthKit] refreshed candidate=\(candidate.externalId)")
                            self?.sendRunUpdate(candidate)
                        case .failure(let error):
                            print("[RunContext HealthKit] refresh failed:", error.localizedDescription)
                            self?.sendRunUpdateError(externalId: request.externalId, message: error.localizedDescription)
                        }
                    }
                }

            default:
                sendError("지원하지 않는 HealthKit 요청입니다.")
            }
        }

        private func numberValue(_ value: Any?) -> Double? {
            if let value = value as? Double {
                return value
            }
            if let value = value as? Int {
                return Double(value)
            }
            if let value = value as? NSNumber {
                return value.doubleValue
            }
            return nil
        }

        private func handleHapticsMessage(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "selectionChanged":
                let styleText = body["style"] as? String
                let style: UIImpactFeedbackGenerator.FeedbackStyle = styleText == "medium" ? .medium : .light
                let generator = UIImpactFeedbackGenerator(style: style)
                generator.prepare()
                generator.impactOccurred(intensity: 0.55)
            default:
                return
            }
        }

        private func handleWeatherMessage(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                sendWeatherError("지원하지 않는 날씨 요청입니다.")
                return
            }

            guard type == "requestWeatherForecast" else {
                sendWeatherError("지원하지 않는 날씨 요청입니다.")
                return
            }

            print("[RunContext Weather] requestWeatherForecast via Open-Meteo")
            weatherImporter.fetchForecast { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let snapshot):
                        print("[RunContext Weather] fetched forecast")
                        self?.sendWeatherForecast(snapshot)
                    case .failure(let error):
                        print("[RunContext Weather] failed:", error.localizedDescription)
                        self?.sendWeatherError(error.localizedDescription)
                    }
                }
            }
        }

        private func handleNotificationMessage(_ message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }

            switch type {
            case "syncNotificationSettings":
                let settings = body["settings"] as? [String: Any] ?? [:]
                let enabled = settings["allEnabled"] as? Bool ?? false
                let payloads = body["notifications"] as? [[String: Any]] ?? []
                let requests = payloads.compactMap(RunContextNotificationRequest.init(payload:))
                print("[RunContext Notifications] received syncNotificationSettings enabled=\(enabled) scheduled=\(requests.count)")
                notificationManager.updateSettings(RunContextNotificationSettings(payload: settings))
                notificationManager.syncScheduledNotifications(enabled: enabled, requests: requests)
            case "showNotification":
                guard let title = body["title"] as? String,
                      let message = body["body"] as? String else {
                    return
                }
                let id = body["id"] as? String ?? "runcontext-now-\(Date().timeIntervalSince1970)"
                notificationManager.showImmediateNotification(id: id, title: title, body: message)
            default:
                return
            }
        }

        private func handleBackgroundHealthKitChange() {
            if UIApplication.shared.applicationState == .active {
                requestWebHealthKitSync(reason: "background-delivery")
                return
            }
            notificationManager.showHealthKitDetectedNotificationIfEnabled()
        }

        private func requestWebHealthKitSync(reason: String) {
            guard let webView else { return }
            let escaped = reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            webView.evaluateJavaScript("window.RunContextHealthKit?.receiveHealthKitChanged('\(escaped)');")
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            if notification.request.identifier.hasPrefix("pacelab-healthkit-detected-") {
                completionHandler([])
                return
            }
            completionHandler([.banner, .sound, .list])
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak webView] in
                guard let webView else { return }
                webView.evaluateJavaScript("document.body.innerText.trim().length") { result, error in
                    if let error {
                        print("[RunContext WebView] inspect failed:", error.localizedDescription)
                        return
                    }

                    if let length = result as? Int, length == 0 {
                        self?.loadDiagnosticPage(in: webView, reason: "Vue 화면이 렌더링되지 않았습니다.")
                        return
                    }

                    self?.signalReadyAfterMinimumDuration()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loadDiagnosticPage(in: webView, reason: "페이지 로딩 실패: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loadDiagnosticPage(in: webView, reason: "초기 페이지 로딩 실패: \(error.localizedDescription)")
        }

        private func sendRuns(_ candidates: [HealthKitRunCandidate]) {
            guard let webView else { return }
            do {
                let data = try JSONEncoder().encode(candidates)
                let json = String(data: data, encoding: .utf8) ?? "[]"
                webView.evaluateJavaScript("window.RunContextHealthKit?.receiveRuns(\(json));")
            } catch {
                sendError("HealthKit 응답 직렬화 실패")
            }
        }

        private func sendRunUpdate(_ candidate: HealthKitRunCandidate) {
            guard let webView else { return }
            do {
                let data = try JSONEncoder().encode(candidate)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                webView.evaluateJavaScript("window.RunContextHealthKit?.receiveRunUpdate(\(json));")
            } catch {
                sendRunUpdateError(externalId: candidate.externalId, message: "HealthKit 갱신 응답 직렬화 실패")
            }
        }

        private func sendWeatherForecast(_ snapshot: RunContextWeatherSnapshot) {
            guard let webView else { return }
            do {
                let data = try JSONEncoder().encode(snapshot)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                webView.evaluateJavaScript("window.RunContextWeatherKit?.receiveForecast(\(json));")
            } catch {
                sendWeatherError("날씨 응답 직렬화 실패")
            }
        }

        private func sendWeatherError(_ message: String) {
            guard let webView else { return }
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            webView.evaluateJavaScript("window.RunContextWeatherKit?.receiveError('\(escaped)');")
        }

        private func sendError(_ message: String) {
            guard let webView else { return }
            let escaped = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            webView.evaluateJavaScript("window.RunContextHealthKit?.receiveError('\(escaped)');")
        }

        private func sendRunUpdateError(externalId: String?, message: String) {
            guard let webView else { return }
            let escapedId = (externalId ?? "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let escapedMessage = message
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            webView.evaluateJavaScript("window.RunContextHealthKit?.receiveRunUpdateError('\(escapedId)', '\(escapedMessage)');")
        }

        private func loadDiagnosticPage(in webView: WKWebView, reason: String) {
            let resources = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: nil)?
                .map { $0.lastPathComponent }
                .sorted()
                .joined(separator: "<br>") ?? "리소스 목록을 읽을 수 없습니다."
            let html = """
            <!doctype html>
            <html lang="ko">
            <head>
              <meta name="viewport" content="width=device-width, initial-scale=1">
              <style>
                body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 24px; line-height: 1.45; color: #111827; }
                h1 { font-size: 20px; }
                code { background: #f3f4f6; padding: 2px 4px; border-radius: 4px; }
                .box { border: 1px solid #d1d5db; border-radius: 8px; padding: 12px; margin-top: 12px; font-size: 13px; overflow-wrap: anywhere; }
              </style>
            </head>
            <body>
              <h1>RunContext 로딩 진단</h1>
              <p>\(reason)</p>
              <p>Xcode 콘솔의 <code>[RunContext WebView]</code> 로그를 확인하세요.</p>
              <div class="box">\(resources)</div>
            </body>
            </html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        private func signalReadyAfterMinimumDuration() {
            guard !didSignalReady else { return }
            didSignalReady = true
            let elapsed = Date().timeIntervalSince(startedAt)
            let delay = max(0, minimumSplashDuration - elapsed)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [onReady] in
                onReady()
            }
        }
    }
}
