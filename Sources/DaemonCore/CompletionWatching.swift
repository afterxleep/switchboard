import Foundation

public protocol CompletionWatching {
    func checkAndProcess(dispatcher: EventDispatching) throws
}
