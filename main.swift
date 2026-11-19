import AppKit
import Carbon
import CoreGraphics
import ImageIO
import NaturalLanguage
import SwiftUI
import Translation
import Vision

private struct TextRegion {
    var text: String
    var bounds: CGRect
    let lineHeight: CGFloat
}

private struct Screenshot {
    let image: CGImage
    let regions: [TextRegion]

    var original: String { regions.map(\.text).joined(separator: "\n") }
}

private final class TranslationResult: ObservableObject {
    @Published var showingOriginal = false
    @Published var translations: [Int: String]?
    @Published var failure: String?
    @Published var configuration: TranslationSession.Configuration?
}

private struct ResultView: View {
    let screenshot: Screenshot
    @StateObject private var result = TranslationResult()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(result.showingOriginal ? "原图" : "简体中文").font(.title2.bold())
                Spacer()
                Button(result.showingOriginal ? "查看译图" : "查看原图") { result.showingOriginal.toggle() }
                if let translations = result.translations {
                    Button("复制译文") {
                        let text = screenshot.regions.indices.compactMap { translations[$0] }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            if let failure = result.failure {
                HStack {
                    Text(failure).foregroundStyle(.secondary)
                    Button("重试") {
                        result.failure = nil
                        result.configuration?.invalidate()
                    }
                }
            } else if result.translations == nil {
                ProgressView("正在使用 Apple 翻译…")
                    .controlSize(.small)
            }
            ScreenshotPreview(screenshot: screenshot, translations: result.showingOriginal ? nil : result.translations)
        }
        .padding(18)
        .frame(minWidth: 440, minHeight: 260)
        .onAppear {
            guard result.configuration == nil, result.translations == nil else { return }
            let original = screenshot.original
            switch NLLanguageRecognizer.dominantLanguage(for: original) {
            case .simplifiedChinese:
                result.translations = translationsByRegion { $0 }
            case .traditionalChinese:
                result.translations = translationsByRegion {
                    $0.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? $0
                }
            case let language:
                result.configuration = .init(
                    source: language.map { Locale.Language(identifier: $0.rawValue) },
                    target: Locale.Language(identifier: "zh-Hans")
                )
            }
        }
        .translationTask(result.configuration) { session in
            do {
                let requests = screenshot.regions.enumerated().map { index, region in
                    TranslationSession.Request(sourceText: region.text, clientIdentifier: String(index))
                }
                let responses = try await session.translations(from: requests)
                guard !Task.isCancelled else { return }
                result.translations = responses.reduce(into: [:]) { translations, response in
                    if let identifier = response.clientIdentifier, let index = Int(identifier) {
                        translations[index] = response.targetText
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                result.failure = "Apple 翻译未完成。\n\(error.localizedDescription)"
            }
        }
    }

    private func translationsByRegion(_ transform: (String) -> String) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: screenshot.regions.enumerated().map { ($0.offset, transform($0.element.text)) })
    }
}

private struct ScreenshotPreview: View {
    let screenshot: Screenshot
    let translations: [Int: String]?

    var body: some View {
        GeometryReader { geometry in
            let image = screenshot.image
            let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height), 2)
            let width = CGFloat(image.width) * scale
            let height = CGFloat(image.height) * scale
            Image(decorative: image, scale: 1)
                .resizable()
                .frame(width: width, height: height)
                .overlay {
                    if let translations {
                        Canvas { context, size in
                            for (index, region) in screenshot.regions.enumerated() {
                                guard let text = translations[index], !text.isEmpty, text != region.text else { continue }
                                let rect = imageRect(for: region, size: size)
                                let background = Color(red: 0.10, green: 0.10, blue: 0.11).opacity(0.98)
                                context.fill(Path(roundedRect: rect, cornerRadius: min(3, rect.height / 5)), with: .color(background))
                                let inset = min(3, rect.height / 10, rect.width / 12)
                                let content = rect.insetBy(dx: inset, dy: inset)
                                let fontSize = region.lineHeight * size.height * 0.88
                                let font = fittingFont(for: text, in: content.size, preferredSize: fontSize)
                                let label = Text(text).font(.system(size: font)).foregroundStyle(.white)
                                context.draw(context.resolve(label), in: content)
                            }
                        }
                        .accessibilityHidden(true)
                    }
                }
                .accessibilityLabel(translations == nil ? "截图原图" : "截图译图")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func imageRect(for region: TextRegion, size: CGSize) -> CGRect {
        // Vision reports normalized coordinates with the origin at the lower left.
        let box = region.bounds
        let rect = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height,
                          width: box.width * size.width, height: box.height * size.height)
        let padding = min(3, region.lineHeight * size.height * 0.12)
        return rect.insetBy(dx: -padding, dy: -padding)
            .intersection(CGRect(origin: .zero, size: size))
    }

    private func fittingFont(for text: String, in size: CGSize, preferredSize: CGFloat) -> CGFloat {
        var lower: CGFloat = 1
        var upper = max(1, preferredSize)
        for _ in 0..<8 {
            let candidate = (lower + upper) / 2
            let font = NSFont.systemFont(ofSize: candidate)
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            if bounds.width <= size.width && bounds.height <= size.height {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return lower
    }
}

enum CaptureError: LocalizedError {
    case screenshotFailed
    case noText

    var errorDescription: String? {
        switch self {
        case .screenshotFailed: "截图失败。请检查系统的屏幕录制权限后重试。"
        case .noText: "没有识别到文字。请框选清晰且包含文字的区域。"
        }
    }
}

private func captureScreenshot() throws -> CGImage? {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ScreenTranslate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("capture.png")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-i", "-s", "-x", url.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw CaptureError.screenshotFailed }
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CaptureError.screenshotFailed
    }
    return image
}

private func recognizeScreenshot(_ image: CGImage) throws -> Screenshot {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true
    request.recognitionLanguages = try request.supportedRecognitionLanguages()
    try VNImageRequestHandler(cgImage: image).perform([request])

    var regions: [TextRegion] = []
    for observation in request.results ?? [] {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = observation.boundingBox.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !text.isEmpty, !box.isEmpty else { continue }

        // Merge nearby, left-aligned lines of comparable size so paragraphs translate together.
        if let last = regions.last {
            let lineHeight = last.lineHeight
            let gap = last.bounds.minY - box.maxY
            if gap >= -lineHeight * 0.15, gap <= lineHeight * 0.65,
               abs(box.minX - last.bounds.minX) * CGFloat(image.width) <= lineHeight * CGFloat(image.height) * 0.65,
               box.height >= lineHeight * 0.75, box.height <= lineHeight * 1.3,
               box.width <= last.bounds.width * 1.25, box.width >= last.bounds.width * 0.3 {
                regions[regions.count - 1].text += " " + text
                regions[regions.count - 1].bounds = last.bounds.union(box)
                continue
            }
        }
        regions.append(TextRegion(text: text, bounds: box, lineHeight: box.height))
    }

    guard !regions.isEmpty else { throw CaptureError.noText }
    return Screenshot(image: image, regions: regions)
}

private struct Shortcut: Codable {
    let label: String
    let modifiers: UInt32
    let key: UInt32

    init(label: String, modifiers: UInt32, key: UInt32) {
        self.label = label
        self.modifiers = modifiers
        self.key = key
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let modifierKeys: [(NSEvent.ModifierFlags, Int, String)] = [
            (.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
            (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
        ]
        let pressed = modifierKeys.filter { flags.contains($0.0) }
        modifiers = pressed.reduce(0) { $0 | UInt32($1.1) }
        key = UInt32(event.keyCode)
        let namedKeys = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "空格", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←",
            kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down"
        ]
        let functionKey = event.charactersIgnoringModifiers?.unicodeScalars.first.flatMap { scalar -> String? in
            guard (0xF704...0xF726).contains(scalar.value) else { return nil }
            return "F\(scalar.value - 0xF704 + 1)"
        }
        let characters = event.charactersIgnoringModifiers?.uppercased()
        let printable = characters.flatMap {
            $0.isEmpty || $0.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value)
            }) ? nil : $0
        }
        let name = namedKeys[Int(key)] ?? functionKey ?? printable ?? "键 \(key)"
        label = pressed.map { $0.2 }.joined() + name
    }

    func matches(_ other: Shortcut) -> Bool {
        key == other.key && modifiers == other.modifiers
    }
}

@MainActor
private final class ShortcutRecorder: NSPanel {
    let message = NSTextField(wrappingLabelWithString: "")
    var onRecord: ((Shortcut) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }
        record(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty {
            close()
        } else if let shortcut = Shortcut(event: event) {
            if onRecord?(shortcut) == true {
                close()
            } else {
                message.stringValue = "\(shortcut.label) 无法注册，可能已被系统或其他应用使用。请试试另一个组合。"
            }
        } else {
            message.stringValue = "请按住 ⌘、⌃ 或 ⌥ 中的至少一个，再按下另一个键。"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shortcuts: [Shortcut] = [
        .init(label: "⌃⇧T", modifiers: UInt32(controlKey | shiftKey), key: UInt32(kVK_ANSI_T)),
        .init(label: "⌥⇧T", modifiers: UInt32(optionKey | shiftKey), key: UInt32(kVK_ANSI_T)),
        .init(label: "⌃⌥T", modifiers: UInt32(controlKey | optionKey), key: UInt32(kVK_ANSI_T)),
        .init(label: "⌃⇧Y", modifiers: UInt32(controlKey | shiftKey), key: UInt32(kVK_ANSI_Y))
    ]
    private let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activeShortcut: Shortcut?
    private var recorder: ShortcutRecorder?
    private var window: NSWindow?
    private var capturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            icon.size = NSSize(width: 18, height: 18)
            icon.accessibilityDescription = "Screen Translate"
            status.button?.image = icon
        } else {
            status.button?.title = "译"
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { app.capture() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: "CaptureShortcut").flatMap {
            try? JSONDecoder().decode(Shortcut.self, from: $0)
        }
        let previousIndex = defaults.integer(forKey: "ShortcutIndex")
        let previous = shortcuts.indices.contains(previousIndex) ? shortcuts[previousIndex] : shortcuts[0]
        if result == noErr {
            for shortcut in [saved ?? previous] + shortcuts {
                if registerShortcut(shortcut) { break }
            }
        }
        updateMenu()
        if CommandLine.arguments.contains("--request-screen-recording"),
           !CGPreflightScreenCaptureAccess() {
            DispatchQueue.main.async { self.openScreenRecordingSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func registerShortcut(_ shortcut: Shortcut) -> Bool {
        guard handler != nil else { return false }
        var replacement: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x5354524C, id: 1)
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &replacement)
        guard result == noErr, let replacement else { return false }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
        activeShortcut = shortcut
        return true
    }

    private func selectShortcut(_ shortcut: Shortcut) -> Bool {
        guard activeShortcut?.matches(shortcut) == true || registerShortcut(shortcut) else { return false }
        UserDefaults.standard.set(try? JSONEncoder().encode(shortcut), forKey: "CaptureShortcut")
        updateMenu()
        return true
    }

    private func updateMenu() {
        let menu = NSMenu()
        let label = activeShortcut.map { "截图翻译（\($0.label)）" } ?? "截图翻译"
        menu.addItem(item(label, #selector(capture)))
        let settings = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        for (index, shortcut) in shortcuts.enumerated() {
            let choice = item(shortcut.label, #selector(changeShortcut(_:)))
            choice.tag = index
            choice.state = activeShortcut?.matches(shortcut) == true ? .on : .off
            choices.addItem(choice)
        }
        choices.addItem(.separator())
        choices.addItem(item("自定义…", #selector(recordShortcut)))
        settings.submenu = choices
        menu.addItem(settings)
        menu.addItem(item("屏幕录制权限…", #selector(openScreenRecordingSettings)))
        menu.addItem(.separator())
        menu.addItem(item("退出 Screen Translate", #selector(quit)))
        status.menu = menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func changeShortcut(_ sender: NSMenuItem) {
        if !selectShortcut(shortcuts[sender.tag]) {
            showAlert("无法注册这个快捷键。请选择另一个组合。")
        }
    }

    @objc private func recordShortcut() {
        if let recorder, recorder.isVisible {
            recorder.makeKeyAndOrderFront(nil)
            return
        }

        let panel = ShortcutRecorder(contentRect: NSRect(x: 0, y: 0, width: 420, height: 116),
                                     styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "自定义截图快捷键"
        panel.isReleasedWhenClosed = false
        panel.onRecord = { [weak self] shortcut in self?.selectShortcut(shortcut) == true }
        let current = activeShortcut.map { "当前快捷键：\($0.label)" } ?? "当前未设置快捷键"
        panel.message.stringValue = "\(current)\n按下新组合即可保存。按 Esc 取消。"
        let content = NSView()
        panel.message.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel.message)
        NSLayoutConstraint.activate([
            panel.message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            panel.message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            panel.message.centerYAnchor.constraint(equalTo: content.centerYAnchor)
        ])
        panel.contentView = content
        recorder = panel
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func openScreenRecordingSettings() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func capture() {
        guard !capturing, recorder?.isKeyWindow != true else { return }
        guard CGPreflightScreenCaptureAccess() else {
            openScreenRecordingSettings()
            return
        }
        window?.close()
        window = nil
        capturing = true
        Task {
            defer { capturing = false }
            do {
                let image = try await Task.detached(priority: .userInitiated) {
                    try captureScreenshot()
                }.value
                guard let image else { return }
                let resultWindow = showResultWindow(
                    ProgressView("正在识别截图文字…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                )
                do {
                    let screenshot = try await Task.detached(priority: .userInitiated) {
                        try recognizeScreenshot(image)
                    }.value
                    guard resultWindow.isVisible else { return }
                    resultWindow.contentView = NSHostingView(rootView: ResultView(screenshot: screenshot))
                } catch {
                    guard resultWindow.isVisible else { return }
                    resultWindow.contentView = NSHostingView(
                        rootView: Text(error.localizedDescription)
                            .multilineTextAlignment(.center)
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    )
                }
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    private func showResultWindow<Content: View>(_ content: Content) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 570),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Screen Translate"
        window.contentMinSize = NSSize(width: 440, height: 260)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func showAlert(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Translate"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    let mainMenu = NSMenu()
    let fileItem = NSMenuItem()
    let fileMenu = NSMenu(title: "文件")
    fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    fileItem.submenu = fileMenu
    mainMenu.addItem(fileItem)
    app.mainMenu = mainMenu
    withExtendedLifetime(delegate) { app.run() }
}
