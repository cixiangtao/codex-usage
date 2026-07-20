import Foundation

enum AppResources {
    private static let resourceBundleName = "CodexUsage_CodexUsage.bundle"

    static let bundle: Bundle = {
        if let packagedBundleURL = Bundle.main.resourceURL?
            .appendingPathComponent(resourceBundleName),
           let packagedBundle = Bundle(url: packagedBundleURL) {
            return packagedBundle
        }

        return .module
    }()
}
