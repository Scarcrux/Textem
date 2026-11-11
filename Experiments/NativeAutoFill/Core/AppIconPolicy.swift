import AppKit
import Foundation

public enum AppIconPolicy {
    public static func accepts(iconFile: String?, data: Data?, reference: Data) -> Bool {
        guard iconFile == "AppIcon" || iconFile == "AppIcon.icns",
              let data, !data.isEmpty, data == reference,
              let image = NSImage(data: data), image.isValid,
              image.size.width >= 16, image.size.height >= 16 else { return false }
        return true
    }
}
