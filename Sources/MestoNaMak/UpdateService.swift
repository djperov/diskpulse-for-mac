import Foundation

struct ReleaseUpdate: Decodable {
    struct Asset: Decodable {
        let name: String
        let downloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case downloadURL = "browser_download_url"
        }
    }

    let version: String
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case version = "tag_name"
        case assets
    }

    var installer: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
            ?? assets.first { $0.name.lowercased().hasSuffix(".zip") }
    }
}

enum UpdateService {
    static let fallbackVersion = "1.1.0"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/djperov/diskpulse-for-mac/releases/latest")!

    static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallbackVersion
    }

    static func latestRelease() async throws -> ReleaseUpdate {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DiskPulse-for-Mac", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noRelease
        }
        return try JSONDecoder().decode(ReleaseUpdate.self, from: data)
    }

    static func isNewer(_ available: String, than installed: String) -> Bool {
        let left = available.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        let right = installed.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func download(_ asset: ReleaseUpdate.Asset) async throws -> URL {
        let (temporaryURL, _) = try await URLSession.shared.download(from: asset.downloadURL)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var destination = downloads.appendingPathComponent(asset.name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (asset.name as NSString).deletingPathExtension
            let extensionName = (asset.name as NSString).pathExtension
            destination = downloads.appendingPathComponent("\(base)-\(suffix).\(extensionName)")
            suffix += 1
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}

enum UpdateError: LocalizedError {
    case noRelease
    case noInstaller

    var errorDescription: String? {
        switch self {
        case .noRelease: return "No published release was found."
        case .noInstaller: return "The release does not contain a DMG or ZIP installer."
        }
    }
}
