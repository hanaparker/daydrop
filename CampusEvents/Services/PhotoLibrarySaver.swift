import Photos
import UIKit

enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case notAllowed
        var errorDescription: String? {
            "The flyer is saved in the app, but not in Photos. Allow photo access in Settings to save flyers there too."
        }
    }

    /// Adds the flyer to the student's photo library (asks for add-only permission once).
    static func save(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}
