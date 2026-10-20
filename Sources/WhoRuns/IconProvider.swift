import SwiftUI
import AppKit

/// Loads and caches real app icons via NSWorkspace so repeated list renders stay cheap.
final class IconProvider {
    static let shared = IconProvider()

    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    /// "/Applications/Slack.app/Contents/MacOS/Slack" -> "/Applications/Slack.app"
    func appBundlePath(for executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        var bundle = String(executablePath[..<range.upperBound])
        if bundle.hasSuffix("/") { bundle.removeLast() }
        return bundle
    }

    func icon(forBundle bundlePath: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: bundlePath) else { return nil }
        lock.lock()
        if let cached = cache[bundlePath] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let image = NSWorkspace.shared.icon(forFile: bundlePath)
        lock.lock()
        cache[bundlePath] = image
        lock.unlock()
        return image
    }
}

/// Group icon: real app icon when available, otherwise a semantic SF Symbol.
struct GroupIconView: View {
    let owner: String
    let representativePath: String?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if owner == "Apple" {
                Image(systemName: "apple.logo")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            } else if let path = representativePath,
                      let bundle = IconProvider.shared.appBundlePath(for: path),
                      let image = IconProvider.shared.icon(forBundle: bundle) {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: size, height: size)
            }
        }
    }

    private var fallbackSymbol: String {
        switch owner {
        case "User-level": return "person.crop.square"
        case "Homebrew", "/usr/local": return "terminal"
        default:
            if owner.hasPrefix("Library:") { return "gearshape.2" }
            return "app.dashed"
        }
    }
}
