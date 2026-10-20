import AppKit
import ImageIO
import Observation
import UniformTypeIdentifiers

nonisolated struct Attachment: Identifiable, Sendable {
    enum Kind: Sendable {
        case image(data: Data, mediaType: String)
        case file(URL)
    }

    let id = UUID()
    let name: String
    let kind: Kind

    var imageData: Data? {
        if case .image(let data, _) = kind { return data }
        return nil
    }

    /// Images are inlined for Claude to see; anything else is handed over by path.
    static func load(_ url: URL) -> Attachment? {
        guard url.isFileURL else { return nil }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if type?.conforms(to: .image) == true, let data = try? Data(contentsOf: url),
           let image = ImageEncoder.prepare(data) {
            return Attachment(name: url.lastPathComponent, kind: .image(data: image.data, mediaType: image.mediaType))
        }
        return Attachment(name: url.lastPathComponent, kind: .file(url))
    }

    static func image(_ data: Data, name: String = "Pasted Image") -> Attachment? {
        guard let image = ImageEncoder.prepare(data) else { return nil }
        return Attachment(name: name, kind: .image(data: image.data, mediaType: image.mediaType))
    }
}

/// Keeps images within the API's limits: ≤ 5 MB and a sane long edge, in a supported format.
nonisolated enum ImageEncoder {
    private static let supported: [String: String] = [
        UTType.png.identifier: "image/png",
        UTType.jpeg.identifier: "image/jpeg",
        UTType.gif.identifier: "image/gif",
        UTType.webP.identifier: "image/webp",
    ]
    private static let maxPixels = 2048
    private static let maxBytes = 3_500_000

    static func prepare(_ data: Data) -> (data: Data, mediaType: String)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        let type = CGImageSourceGetType(source) as String?

        if let type, let mediaType = supported[type], max(width, height) <= maxPixels, data.count <= maxBytes {
            return (data, mediaType)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)

        let output = NSMutableData()
        let format = hasAlpha ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(output, format.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, hasAlpha ? "image/png" : "image/jpeg")
    }
}

/// What's typed in a composer but not sent yet, kept per session.
@Observable
final class Draft {
    var text = ""
    var attachments: [Attachment] = []

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    func add(_ urls: [URL]) {
        attachments += urls.compactMap(Attachment.load)
    }

    /// Takes files or image data from a pasteboard. Returns false when there's nothing to attach,
    /// so plain text pastes fall through to the text field.
    func paste(from pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            add(urls)
            return true
        }
        guard pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
              let attachment = Attachment.image(data)
        else { return false }
        attachments.append(attachment)
        return true
    }

    /// Takes a drag: Finder files arrive as file URLs; images dragged from a browser or Photos arrive as data.
    func drop(from pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            add(urls)
            return true
        }
        guard let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
                ?? pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.image.identifier)),
              let attachment = Attachment.image(data, name: "Dropped Image")
        else { return false }
        attachments.append(attachment)
        return true
    }

    /// Whether a drag carries something worth attaching, rather than text for the field.
    static func canDrop(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType(UTType.image.identifier)]) != nil
    }

    func clear() {
        text = ""
        attachments = []
    }
}
