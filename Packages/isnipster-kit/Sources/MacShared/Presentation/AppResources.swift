import AppKit

public enum AppResources {
    public static let bundle = Bundle.module
    @MainActor
    public static func image(named name: String) -> NSImage? {
        Bundle.module.image(forResource: name)?.copy() as? NSImage
    }
}
