import AppKit
import Foundation

/// 主线程仅更新启动结果；设备线程查询结果，不等待信号量、不阻塞心跳。
final class ApplicationActivation: @unchecked Sendable {
    enum State { case pending, launched, failed, cancelled }
    private let lock = NSLock()
    private var value = State.pending
    var state: State { lock.lock(); defer { lock.unlock() }; return value }
    func complete(_ success: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard case .pending = value else { return }
        value = success ? .launched : .failed
    }
    func cancel() { lock.lock(); value = .cancelled; lock.unlock() }
}

struct ApplicationLauncher {
    var launch: (ApplicationTarget) -> ApplicationActivation
    var isFrontmost: (ApplicationTarget) -> Bool

    static let native = ApplicationLauncher(launch: { target in
        let activation = ApplicationActivation()
        DispatchQueue.main.async {
            guard case .pending = activation.state else { return }
            let workspace = NSWorkspace.shared
            let specified = target.path.isEmpty ? nil : URL(fileURLWithPath: target.path)
            let url = specified.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
                ?? (target.bundleIdentifier.isEmpty ? nil : workspace.urlForApplication(withBundleIdentifier: target.bundleIdentifier))
            guard let url, let bundle = Bundle(url: url),
                  target.bundleIdentifier.isEmpty || bundle.bundleIdentifier == target.bundleIdentifier else {
                activation.complete(false)
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.openApplication(at: url, configuration: configuration) { application, error in
                activation.complete(application != nil && error == nil)
            }
        }
        return activation
    }, isFrontmost: { target in
        guard let application = NSWorkspace.shared.frontmostApplication else { return false }
        if !target.bundleIdentifier.isEmpty { return application.bundleIdentifier == target.bundleIdentifier }
        return application.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: target.path).standardizedFileURL.path
    })
}

/// 所有步骤在设备线程分次推进；同一控件最多一个动作，全局最多八个动作。
final class HostActionRunner {
    static let keyboardOwner = -1
    private struct Work { let index: Int; var steps: [MacroStep] }
    private enum Wait {
        case delay(TimeInterval)
        case release(TimeInterval)
        case application(ApplicationTarget, ApplicationActivation, TimeInterval)
    }
    private var queue: [Work] = []
    private var current: Work?
    private var waiting: Wait?
    private var expectedForeground: ApplicationTarget?
    private let launcher: ApplicationLauncher

    init(launcher: ApplicationLauncher = .native) { self.launcher = launcher }

    @discardableResult
    func enqueue(index: Int, action: HostAction) throws -> Bool {
        try action.validate()
        guard current?.index != index, !queue.contains(where: { $0.index == index }),
              queue.count + (current == nil ? 0 : 1) < 8 else { return false }
        let steps: [MacroStep]
        switch action {
        case .keyboard(let entries): steps = [.keyboard(entries)]
        case .application(let target): steps = [.application(target)]
        case .macro(let sequence): steps = sequence
        case .library: throw HostActionError.missingLibraryAction
        }
        queue.append(Work(index: index, steps: steps))
        return true
    }

    func cancel() {
        if case .application(_, let activation, _) = waiting { activation.cancel() }
        waiting = nil
        current = nil
        queue.removeAll()
        expectedForeground = nil
    }

    func pump(at now: TimeInterval, press: ([KeyEntry]) throws -> Void, release: () throws -> Void) throws {
        do {
            try advance(at: now, press: press, release: release)
        } catch {
            // 发键失败或用户切走前台后，不能继续运行积压动作。
            cancel()
            try? release()
            throw error
        }
    }

    private func advance(at now: TimeInterval, press: ([KeyEntry]) throws -> Void, release: () throws -> Void) throws {
        // 等待期间也持续检查；用户切走又切回，不应复活已经失去目标的宏。
        if let expectedForeground, !launcher.isFrontmost(expectedForeground) {
            throw HostActionError.foregroundChanged
        }
        if let waiting {
            switch waiting {
            case .delay(let deadline):
                guard now >= deadline else { return }
            case .release(let deadline):
                guard now >= deadline else { return }
                try release()
            case .application(let target, let activation, let deadline):
                switch activation.state {
                case .failed, .cancelled: throw HostActionError.activationFailed
                case .pending:
                    guard now < deadline else { throw HostActionError.activationFailed }
                    return
                case .launched:
                    guard launcher.isFrontmost(target) else {
                        guard now < deadline else { throw HostActionError.activationFailed }
                        return
                    }
                    expectedForeground = target
                }
            }
            self.waiting = nil
        }
        if let current, current.steps.isEmpty { self.current = nil; expectedForeground = nil }
        if current == nil {
            guard !queue.isEmpty else { return }
            current = queue.removeFirst()
        }
        guard let step = current?.steps.first else { return }
        current?.steps.removeFirst()
        switch step {
        case .delay(let duration): waiting = .delay(now + duration)
        case .application(let target):
            expectedForeground = nil
            waiting = .application(target, launcher.launch(target), now + 5)
        case .keyboard(let entries):
            if let expectedForeground, !launcher.isFrontmost(expectedForeground) {
                throw HostActionError.foregroundChanged
            }
            try press(entries)
            waiting = .release(now + 0.04)
        }
    }
}
