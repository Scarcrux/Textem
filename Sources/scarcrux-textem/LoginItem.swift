import Foundation
import ServiceManagement

// Launch-at-login via SMAppService (macOS 13+). Registration can fail for an
// unsigned/ad-hoc build or one outside /Applications; failures are logged,
// not fatal, and `isEnabled` reflects the real system state.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Textem: login-item toggle failed: \(error.localizedDescription)")
        }
    }
}
