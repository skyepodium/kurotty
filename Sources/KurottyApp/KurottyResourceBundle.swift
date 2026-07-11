import Foundation

enum KurottyResourceBundle {
    private static let bundleName = "Kurotty_KurottyApp"

    static var bundle: Bundle? {
        if let resourceURL = Bundle.main.resourceURL,
           let installedBundle = Bundle(
               url: resourceURL.appendingPathComponent("\(bundleName).bundle", isDirectory: true)
           ) {
            return installedBundle
        }

        return Bundle.module
    }
}
