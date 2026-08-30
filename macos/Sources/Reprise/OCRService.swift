import Foundation
import ImageIO
import Vision

enum OCRServiceError: LocalizedError {
    case unreadableImage
    case noText

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "This image could not be opened."
        case .noText: "No terminal text was found in this screenshot."
        }
    }
}

enum OCRService {
    static func recognizeText(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OCRServiceError.unreadableImage
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OCRServiceError.noText
            }
            return text
        }.value
    }
}
