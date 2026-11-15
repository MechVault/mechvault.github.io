import Foundation
import CoreGraphics
import ImageIO
import Vision
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif

func fail(_ msg: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(code)
}

func writeBGRA(_ img: CGImage, to path: String) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { fail("context", 4) }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var data = Data()
    var ww = Int32(w).littleEndian, hh = Int32(h).littleEndian
    data.append(Data(bytes: &ww, count: 4))
    data.append(Data(bytes: &hh, count: 4))
    data.append(contentsOf: buf)
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { fail("write", 5) }
}

func windowInfo(pid: pid_t) -> (CGWindowID, CGRect)? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: (CGWindowID, CGRect)? = nil
    for w in list {
        guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid,
              let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
              let num = w[kCGWindowNumber as String] as? UInt32,
              let b = w[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
        if best == nil || rect.width * rect.height > best!.1.width * best!.1.height { best = (CGWindowID(num), rect) }
    }
    return best
}

func capture(pid: pid_t, out: String) {
    if !CGPreflightScreenCaptureAccess() { fail("no permission", 3) }
    guard let (wid, rect) = windowInfo(pid: pid), rect.width >= 200, rect.height >= 150 else { fail("no window", 2) }
    #if canImport(ScreenCaptureKit)
    if #available(macOS 14.0, *) {
        let sem = DispatchSemaphore(value: 0)
        var result: CGImage? = nil
        Task {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let win = content.windows.first(where: { $0.windowID == wid }) else { return }
                let filter = SCContentFilter(desktopIndependentWindow: win)
                let cfg = SCStreamConfiguration()
                let scale = CGFloat(filter.pointPixelScale)
                cfg.width = Int(win.frame.width * scale)
                cfg.height = Int(win.frame.height * scale)
                cfg.showsCursor = false
                result = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            } catch { }
        }
        sem.wait()
        guard let img = result else { fail("capture failed", 6) }
        writeBGRA(img, to: out)
        return
    }
    #endif
    guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, wid, [.boundsIgnoreFraming, .nominalResolution]) else { fail("capture failed", 6) }
    writeBGRA(img, to: out)
}

func ocr(path: String) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("image", 7) }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: img, options: [:])
    do { try handler.perform([req]) } catch { fail("vision", 8) }
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    print(lines.joined(separator: " "))
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: mvhelper perm|request|capture <pid> <out>|ocr <png>", 1) }
switch args[1] {
case "perm": print(CGPreflightScreenCaptureAccess() ? "granted" : "denied")
case "request": print(CGRequestScreenCaptureAccess() ? "granted" : "denied")
case "capture":
    guard args.count >= 4, let pid = Int32(args[2]) else { fail("usage", 1) }
    capture(pid: pid, out: args[3])
case "ocr":
    guard args.count >= 3 else { fail("usage", 1) }
    ocr(path: args[2])
default: fail("unknown command", 1)
}
