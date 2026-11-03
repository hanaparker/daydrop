import Foundation
import UIKit
import Vision

/// What the app read off a flyer. Every field is editable before saving.
struct ScannedFlyer {
    var title: String
    var start: Date
    var end: Date
    var location: String
    var details: String
    var registrationURL: URL?
    var foundDate: Bool
}

struct RecognizedLine {
    var text: String
    /// Height of the text relative to the image; bigger usually means it's the headline.
    var height: CGFloat
    /// Distance from the top of the image (0 = top), for reading order.
    var top: CGFloat
}

enum FlyerScanError: LocalizedError {
    case unreadableImage
    var errorDescription: String? { "That photo couldn't be read. Try again with the flyer filling the frame." }
}

/// Reads flyers on the device with Apple's Vision framework — no image leaves the phone.
enum FlyerScanner {
    static func scan(_ image: UIImage, now: Date = .now) async throws -> ScannedFlyer {
        guard let cgImage = image.cgImage else { throw FlyerScanError.unreadableImage }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        let (lines, qrPayloads) = try await Task.detached(priority: .userInitiated) {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let barcodeRequest = VNDetectBarcodesRequest()
            barcodeRequest.symbologies = [.qr]

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
            try handler.perform([textRequest, barcodeRequest])

            let lines = (textRequest.results ?? []).compactMap { observation -> RecognizedLine? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(
                    text: candidate.string,
                    height: observation.boundingBox.height,
                    top: 1 - observation.boundingBox.maxY
                )
            }
            .sorted { $0.top < $1.top }
            let payloads = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
            return (lines, payloads)
        }.value

        return FlyerParser.parse(lines: lines, qrPayloads: qrPayloads, now: now)
    }
}

enum FlyerParser {
    static func parse(lines: [RecognizedLine], qrPayloads: [String], now: Date) -> ScannedFlyer {
        let fullText = lines.map(\.text).joined(separator: "\n")
        let dates = TextDateExtractor.extract(from: fullText, now: now)
        let start = dates?.start ?? defaultStart(now: now)
        let end = dates?.end ?? start.addingTimeInterval(3600)

        let location = findLocation(in: lines)
        let titleIndexes = findTitleIndexes(in: lines, excluding: location?.index)
        let title = titleIndexes.map { tidy(lines[$0].text) }.joined(separator: " ")

        let used = Set(titleIndexes + [location?.index].compactMap { $0 })
        let details = lines.indices
            .filter { !used.contains($0) }
            .map { lines[$0].text }
            .joined(separator: "\n")

        return ScannedFlyer(
            title: title,
            start: start,
            end: end,
            location: location?.text ?? "",
            details: String(details.prefix(1000)),
            registrationURL: RegistrationLinkFinder.find(in: fullText, qrPayloads: qrPayloads),
            foundDate: dates != nil
        )
    }

    /// The headline is the biggest text that isn't a date, time or place.
    private static func findTitleIndexes(in lines: [RecognizedLine], excluding locationIndex: Int?) -> [Int] {
        let candidates = lines.indices.filter { i in
            let text = lines[i].text
            return i != locationIndex
                && text.filter(\.isLetter).count >= 3
                && !TextDateExtractor.containsDay(text)
                && !TextDateExtractor.containsTime(text)
        }
        guard let tallest = candidates.map({ lines[$0].height }).max() else { return [] }
        // Multi-line headlines: keep every line nearly as tall as the tallest, in reading order.
        return Array(candidates.filter { lines[$0].height >= tallest * 0.75 }.prefix(3))
    }

    private static let locationPrefixes = ["location:", "where:", "place:", "venue:", "@ "]
    private static let locationWords = [
        "room", "rm.", "hall", "library", "auditorium", "center", "centre", "lounge",
        "theatre", "theater", "building", "lawn", "steps", "chapel", "floor", "suite"
    ]

    private static func findLocation(in lines: [RecognizedLine]) -> (index: Int, text: String)? {
        func cleaned(_ text: String) -> String {
            var result = text.trimmingCharacters(in: .whitespaces)
            for prefix in locationPrefixes where result.lowercased().hasPrefix(prefix) {
                result = String(result.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return result
        }
        // 1. A known Barnard or Columbia building.
        for (i, line) in lines.enumerated() {
            let lower = line.text.lowercased()
            if CampusPlaces.all.contains(where: { lower.contains($0) }) { return (i, cleaned(line.text)) }
        }
        // 2. A line labeled as the location.
        for (i, line) in lines.enumerated()
        where locationPrefixes.contains(where: { line.text.lowercased().hasPrefix($0) }) {
            return (i, cleaned(line.text))
        }
        // 3. Anything that looks like a room or building.
        for (i, line) in lines.enumerated() {
            // Pad and replace punctuation (except ".") so "Lerner Hall," matches " hall ".
            let words = line.text.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : " " }
            let padded = " " + String(words) + " "
            if locationWords.contains(where: { padded.contains(" \($0) ") }) {
                return (i, cleaned(line.text))
            }
        }
        // 4. A street address.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) {
            for (i, line) in lines.enumerated()
            where detector.firstMatch(in: line.text, range: NSRange(line.text.startIndex..., in: line.text)) != nil {
                return (i, cleaned(line.text))
            }
        }
        return nil
    }

    /// FLYERS ARE OFTEN IN ALL CAPS → "Flyers Are Often In All Caps".
    private static func tidy(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = trimmed.filter(\.isLetter)
        if letters.count > 3, letters == letters.uppercased() { return trimmed.capitalized }
        return trimmed
    }

    /// When no date is found: the next whole hour, so the student only has to fix the day.
    private static func defaultStart(now: Date) -> Date {
        let calendar = Calendar.campus
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return hour.addingTimeInterval(3600)
    }
}

/// Building names that show up on campus flyers (lowercased for matching).
enum CampusPlaces {
    static let all: [String] = [
        // Barnard
        "barnard hall", "milstein", "diana center", "the diana", "altschul", "sulzberger",
        "held lecture hall", "james room", "event oval", "lehman auditorium", "futter field",
        // Columbia — Morningside
        "lerner", "butler library", "low library", "low steps", "pupin", "mudd", "schermerhorn",
        "hamilton hall", "philosophy hall", "fayerweather", "avery", "uris", "kent hall", "dodge",
        "international affairs", "iab", "lewisohn", "havemeyer", "northwest corner", "faculty house",
        "st. paul's chapel", "st paul's chapel", "earl hall", "miller theatre", "casa italiana",
        "maison française", "maison francaise", "buell hall", "knox hall", "pulitzer hall",
        "mathematics hall", "math hall", "college walk", "south lawn", "john jay", "wien", "furnald",
        "kraft center", "journalism", "jerome greene", "warren hall", "wallach",
        // Columbia — Manhattanville
        "the forum", "lenfest center", "zuckerman institute", "geffen hall", "kravis"
    ]
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

extension UIImage {
    /// A smaller JPEG copy for keeping the flyer inside the app.
    func jpegForStorage(maxDimension: CGFloat = 2000) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return jpegData(compressionQuality: 0.75) }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let resized = UIGraphicsImageRenderer(size: newSize).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
        return resized.jpegData(compressionQuality: 0.75)
    }
}
