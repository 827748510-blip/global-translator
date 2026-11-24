import Foundation

public enum RuntimeState: String, Codable, Equatable, Sendable {
    case starting
    case running
    case stopping
    case stopped
    case unavailable
    case error
}

public enum ControlAction: String, Codable, Equatable, Sendable {
    case status
    case stop
    case showSettings
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public let action: ControlAction

    public init(action: ControlAction) {
        self.action = action
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public let running: Bool
    public let state: RuntimeState
    public let pid: Int32

    public init(running: Bool, state: RuntimeState, pid: Int32 = 0) {
        self.running = running
        self.state = state
        self.pid = pid
    }
}
