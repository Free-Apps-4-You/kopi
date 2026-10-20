import Foundation
import CopilyCore

/// Human-readable text for the failures the UI can meet. The core's errors are
/// precise but terse, and none of these messages ever contains clipboard content.
func userFacingDescription(_ error: any Error) -> String {
    switch error {
    case let error as HistoryStoreError:
        switch error {
        case .itemNotFound: return "That card no longer exists."
        case .invalidInsertion(let reason): return "The card could not be stored: \(reason)"
        case .emptyEdit: return "There is nothing to save."
        case .contentNotEditable(let kind): return "\(kind.displayName) content cannot be edited. You can change its label."
        case .pinningFailed(_, let reason): return "The card could not be pinned: \(reason)"
        case .stateChanged: return "The card changed while it was being saved. Try again."
        case .assetNotFound: return "The stored content of that card is missing."
        }
    case let error as ClipboardServiceError:
        switch error {
        case .nothingToWrite: return "That card has no content Copily can copy."
        case .clipboardChanged: return "The clipboard changed while Copily was reading it. Try again."
        }
    case let error as AssetStoreError:
        switch error {
        case .sourceUnavailable(let path): return "The original is no longer available at \(path)."
        case .copyFailed(let reason): return "The copy failed: \(reason)"
        case .writeFailed(let reason): return "The copy could not be written: \(reason)"
        case .assetNotFound: return "The stored copy of that content is missing."
        case .invalidRelativePath: return "The stored path is not valid."
        case .insufficientSpace(let path): return "There is not enough space to preserve \(path)."
        }
    case let error as PasteboardAccessError:
        switch error {
        case .accessDenied: return "macOS is not allowing Copily to read the clipboard."
        case .readFailed(let reason): return "The clipboard could not be read: \(reason)"
        case .writeFailed(let reason): return "The clipboard could not be written: \(reason)"
        }
    case let error as NotesClientError:
        return error.userMessage
    case let error as CaptureProcessorError:
        switch error {
        case .unsupportedContent: return "The clipboard holds nothing Copily can store."
        }
    case let error as EditorValidation:
        switch error {
        case .invalidURL: return "That is not a link Copily can save. Enter a web address, for example copily.dev."
        case .emptyNewItem: return "Type something to save this item, or cancel to discard it."
        }
    default:
        return error.localizedDescription
    }
}
