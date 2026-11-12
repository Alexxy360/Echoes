import CloudKit
import Foundation

public enum CloudKitFailure: Error, Equatable, Sendable, LocalizedError {
    case configuration, notAuthenticated, restricted, unavailable, permissionDenied
    case conflict, missingRecord, partialFailure, cancelled
    case retryLater(after: TimeInterval?)

    public var errorDescription: String? {
        switch self {
        case .configuration: "Usługa iCloud nie jest jeszcze skonfigurowana dla tej aplikacji."
        case .notAuthenticated: "Zaloguj się do iCloud w ustawieniach urządzenia."
        case .restricted: "Dostęp do iCloud jest ograniczony na tym urządzeniu."
        case .unavailable: "iCloud jest chwilowo niedostępny. Spróbuj ponownie później."
        case .permissionDenied: "Nie masz uprawnień do tej operacji."
        case .conflict: "Dane zostały zmienione. Odśwież je przed ponownym zapisem."
        case .missingRecord: "Te dane nie są już dostępne."
        case .partialFailure:
            "Operacja została wykonana tylko częściowo. Sprawdź jej wynik przed ponowieniem."
        case .cancelled: "Operacja została anulowana."
        case .retryLater: "iCloud ograniczył liczbę żądań. Spróbuj ponownie później."
        }
    }

    public static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let failure = error as? Self { return failure }
        guard let error = error as? CKError else { return .unavailable }
        switch error.code {
        case .notAuthenticated: return .notAuthenticated
        case .permissionFailure: return .permissionDenied
        case .badContainer, .badDatabase, .missingEntitlement, .incompatibleVersion:
            return .configuration
        case .serverRecordChanged: return .conflict
        case .unknownItem: return .missingRecord
        case .partialFailure: return .partialFailure
        case .operationCancelled: return .cancelled
        case .requestRateLimited, .serviceUnavailable, .zoneBusy:
            let delay = error.retryAfterSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            return .retryLater(after: delay)
        default: return .unavailable
        }
    }
}
