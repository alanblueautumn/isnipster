import Foundation
import OSLog

/// 保留诊断所需的值，不跨隔离域保存 NSError.userInfo 中可能包含的业务内容。
public struct OperationFailure: LocalizedError, Sendable {
    public enum Category: String, Sendable {
        case permission, unsupportedLanguage, network, decoding, systemService, persistence, timeout
    }

    public let category: Category
    public let stage: String
    public let message: String
    public let underlyingDomain: String?
    public let underlyingCode: Int?

    public init(category: Category, stage: String, message: String, underlying: (any Error)? = nil) {
        self.category = category
        self.stage = stage
        self.message = message
        let nested = underlying as? OperationFailure
        underlyingDomain = nested?.underlyingDomain ?? underlying.map { ($0 as NSError).domain }
        underlyingCode = nested?.underlyingCode ?? underlying.map { ($0 as NSError).code }
    }

    public var errorDescription: String? { message }
}

public enum TaskCancellation {
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let failure = error as? AppFailure, case .cancelled = failure { return true }
        let systemError = error as NSError
        return systemError.domain == NSURLErrorDomain && systemError.code == NSURLErrorCancelled
    }
}

/// 只记录固定阶段、请求身份与错误分类/代码，禁止记录正文、路径、URL 或 localizedDescription。
public enum AppDiagnostics {
    private static func categoryName(for error: any Error) -> String {
        if let failure = error as? AppFailure {
            return switch failure {
            case .permissionDenied: "permission"
            case .invalidData: "decoding"
            case .unavailable: "unavailable"
            case .operationFailed: "operation"
            case .cancelled: "cancelled"
            }
        }
        return "systemService"
    }

    private static let logger = Logger(subsystem: "com.isnipster", category: "operations")

    public static func failure(_ error: any Error, stage: String, requestID: UUID? = nil) {
        guard !TaskCancellation.isCancellation(error) else { return }
        let failure = error as? OperationFailure
        let systemError = error as NSError
        let domain = failure?.underlyingDomain ?? systemError.domain
        let code = failure?.underlyingCode ?? systemError.code
        let category = failure?.category.rawValue ?? categoryName(for: error)
        let origin = failure?.stage ?? stage
        let request = requestID?.uuidString ?? "none"
        logger.error("stage=\(stage, privacy: .public) origin=\(origin, privacy: .public) request=\(request, privacy: .public) category=\(category, privacy: .public) domain=\(domain, privacy: .public) code=\(code)")
    }
}
