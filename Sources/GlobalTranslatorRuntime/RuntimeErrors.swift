import Foundation

public enum RuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidPath
    case invalidArguments
    case ioFailure
    case lockUnavailable(pid: Int32?)
    case socketUnavailable
    case socketInUse
    case connectionFailure
    case invalidRequest
    case requestTooLarge
    case responseTooLarge
    case notRunning
    case notReady
    case processLaunchFailure

    public var description: String {
        switch self {
        case .invalidPath:
            return "路径无效"
        case .invalidArguments:
            return "参数无效"
        case .ioFailure:
            return "文件操作失败"
        case let .lockUnavailable(pid):
            if let pid {
                return "已有运行实例（PID \(pid)）"
            }
            return "已有运行实例"
        case .socketUnavailable:
            return "控制 socket 不可用"
        case .socketInUse:
            return "控制 socket 已被占用"
        case .connectionFailure:
            return "控制连接失败"
        case .invalidRequest:
            return "控制请求无效"
        case .requestTooLarge:
            return "控制请求超过 4KiB 限制"
        case .responseTooLarge:
            return "控制响应超过 4KiB 限制"
        case .notRunning:
            return "服务未运行"
        case .notReady:
            return "服务未在限定时间内就绪"
        case .processLaunchFailure:
            return "后台进程启动失败"
        }
    }
}
