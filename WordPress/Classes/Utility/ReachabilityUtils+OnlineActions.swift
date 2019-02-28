import Foundation
import WordPressFlux

extension ReachabilityUtils {
    private enum NoConnectionMessages {
        static let title = NSLocalizedString("No Connection",
                comment: "Title of error prompt when no internet connection is available.")
        static let message = noConnectionMessage()
    }

    /// Performs the action when an internet connection is available
    /// If no internet connection is available an error message is displayed
    ///
    @objc class func onAvailableInternetConnectionDo(_ action: () -> Void) {
        guard ReachabilityUtils.isInternetReachable() else {
            WPError.showAlert(withTitle: NoConnectionMessages.title, message: NoConnectionMessages.message)
            return
        }
        action()
    }

    /// Performs the action once when internet becomes reachable.
    ///
    /// This returns an opaque value similar to what
    /// NotificationCenter.addObserver(forName:object:queue:using:) returns.
    /// You can keep a reference to this if you want to cancel the observer by
    /// calling NotificationCenter.removeObserver(_:)
    ///
    @discardableResult
    @objc class func observeOnceInternetAvailable(action: @escaping () -> Void) -> NSObjectProtocol {
        return NotificationCenter.default.observeOnce(
            forName: .reachabilityChanged,
            object: nil,
            queue: .main,
            using: { _ in action() },
            filter: { (notification) in
                return notification.userInfo?[Foundation.Notification.reachabilityKey] as? Bool == true
        })
    }

    /// Shows a generic non-blocking "No Connection" error message to the user.
    ///
    /// We use a Snackbar instead of a literal Alert because, for internet connection errors,
    /// Alerts can be disruptive.
    @objc class func showNoInternetConnectionNotice() {
        let notice = Notice(title: NoConnectionMessages.title, message: NoConnectionMessages.message)
        ActionDispatcher.dispatch(NoticeAction.post(notice))
    }
}
