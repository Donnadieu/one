import Quartz
import SwiftUI
import AppKit
import AVFoundation
import Speech
import PDFKit
import Carbon
import EventKit
import CoreAudio
import UniformTypeIdentifiers

// MARK: - Pictures (drag, paste, pick, or drop on the orb)

struct Picture: Identifiable {
    let id = UUID()
    let name: String
    let data: Data  // JPEG, at most 1600px on the long side
    let thumb: NSImage

    static func from(url: URL) -> Picture? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        return from(image: img, name: url.lastPathComponent)
    }
    static func from(image: NSImage, name: String = "Picture") -> Picture? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        let k = min(1, 1600 / max(w, h))
        let nw = max(1, Int(w * k))
        let nh = max(1, Int(h * k))
        guard
            let ctx = CGContext(
                data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let out = ctx.makeImage(),
            let jpg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return Picture(name: name, data: jpg, thumb: NSImage(cgImage: out, size: NSSize(width: nw, height: nh)))
    }
    /// Pictures from the clipboard (a copied screenshot or image, or copied image files).
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Picture] {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
            !urls.isEmpty
        {
            return urls.compactMap { from(url: $0) }
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] { return imgs.compactMap { from(image: $0) } }
        return []
    }
}

/// A file you hand to the assistant. It's copied into One's own folder so the assistant can open it
/// without being given access to the folder it came from. PDFs also get a plain-text copy.
struct SharedFile: Identifiable {
    let id = UUID()
    let name: String
    let copy: URL
    let textCopy: URL?
    static let maxBytes = 200 * 1024 * 1024

    static func from(url: URL) -> SharedFile? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxBytes { return nil }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let dir = Env.support.appendingPathComponent("Shared with me/\(day)/\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else { return nil }
        var txt: URL? = nil
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: dest), let text = doc.string,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let t = dest.appendingPathExtension("txt")
            if (try? text.write(to: t, atomically: true, encoding: .utf8)) != nil { txt = t }
        }
        return SharedFile(name: url.lastPathComponent, copy: dest, textCopy: txt)
    }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: copy.path) }
}

@MainActor enum PictureIn {
    static func add(_ p: [Picture]) {
        guard !p.isEmpty else { return }
        Model.shared.pictures.append(contentsOf: p.prefix(max(0, 6 - Model.shared.pictures.count)))
    }
    static func addFiles(_ f: [SharedFile]) {
        guard !f.isEmpty else { return }
        Model.shared.files.append(contentsOf: f.prefix(max(0, 10 - Model.shared.files.count)))
    }
    static func isImage(_ u: URL) -> Bool { (UTType(filenameExtension: u.pathExtension)?.conforms(to: .image)) ?? false }
    /// Pictures go in as pictures; everything else goes in as a file.
    static func addURLs(_ urls: [URL]) -> Int {
        let pics = urls.filter(isImage).compactMap { Picture.from(url: $0) }
        let files = urls.filter { !isImage($0) }.compactMap { SharedFile.from(url: $0) }
        add(pics)
        addFiles(files)
        let skipped = urls.count - pics.count - files.count
        if skipped > 0 { Floater.shared.note("I can take files, not folders, and nothing over 200 MB.") }
        return pics.count + files.count
    }
    static func pick() {
        let o = NSOpenPanel()
        o.allowsMultipleSelection = true
        o.canChooseDirectories = false
        o.message = "Pick pictures or files to give your assistant"
        if o.runModal() == .OK { _ = addURLs(o.urls) }
    }
    static func drop(_ providers: [NSItemProvider]) -> Bool {
        var any = false
        for pr in providers {
            if pr.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                any = true
                _ = pr.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    DispatchQueue.main.async { _ = addURLs([u]) }
                }
            } else if pr.canLoadObject(ofClass: NSImage.self) {
                any = true
                _ = pr.loadObject(ofClass: NSImage.self) { img, _ in
                    guard let img = img as? NSImage, let pic = Picture.from(image: img) else { return }
                    DispatchQueue.main.async { add([pic]) }
                }
            }
        }
        return any
    }
    /// ⌘V with a picture on the clipboard attaches it (text pastes stay normal).
    static func installPaste() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "v",
                Model.shared.onboarded
            else { return e }
            let pb = NSPasteboard.general
            let hasText = pb.string(forType: .string) != nil && pb.availableType(from: [.png, .tiff, .fileURL]) == nil
            if hasText { return e }
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                return addURLs(urls) > 0 ? nil : e
            }
            let pics = Picture.fromPasteboard(pb)
            if pics.isEmpty { return e }
            add(pics)
            return nil
        }
    }
}

struct PictureStrip: View {
    @ObservedObject var m: Model
    var body: some View {
        if !m.pictures.isEmpty || !m.files.isEmpty || m.about != nil {
            HStack(spacing: 8) {
                if let a = m.about {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").foregroundStyle(Color(hex: 0xFFE2C2))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Asking about").font(.caption2).foregroundStyle(.secondary)
                            Text(a.title).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180, alignment: .leading)
                        }
                        Button {
                            m.about = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Remove")
                    }
                    .padding(.horizontal, 10).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                }
                ForEach(m.files) { f in
                    HStack(spacing: 6) {
                        Image(nsImage: f.icon).resizable().frame(width: 26, height: 26)
                        Text(f.name).font(.callout).lineLimit(1).truncationMode(.middle).frame(maxWidth: 140, alignment: .leading)
                        Button {
                            m.files.removeAll { $0.id == f.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain).help("Remove")
                    }
                    .padding(.horizontal, 10).frame(height: 56)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                }
                ForEach(m.pictures) { p in
                    Image(nsImage: p.thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                m.pictures.removeAll { $0.id == p.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }.buttonStyle(.plain).offset(x: 6, y: -6).help("Remove")
                        }
                }
                Spacer()
            }.padding(.horizontal, 6)
        }
    }
}
