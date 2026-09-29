import AppKit
import UniformTypeIdentifiers
import ImageIO

enum OutputFormat: Int {
    case jpeg = 0, png = 1
    var fileExtension: String { self == .jpeg ? "jpg" : "png" }
    var typeIdentifier: CFString { self == .jpeg ? UTType.jpeg.identifier as CFString : UTType.png.identifier as CFString }
}

enum OutputLocation: Int { case subfolder = 0, besideOriginal = 1, custom = 2 }

enum ConversionError: LocalizedError {
    case cannotRead, cannotDecode, cannotCreateOutput, cannotWrite, missingOutputFolder
    var errorDescription: String? {
        switch self {
        case .cannotRead: return "无法读取文件"
        case .cannotDecode: return "无法解码 HEIC 图片"
        case .cannotCreateOutput: return "无法创建输出文件"
        case .cannotWrite: return "写入图片失败"
        case .missingOutputFolder: return "未选择输出文件夹"
        }
    }
}

protocol DropAreaDelegate: AnyObject { func didDrop(urls: [URL]) }

final class DropAreaView: NSView {
    weak var delegate: DropAreaDelegate?
    private var targeted = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])

        let icon = NSImageView(image: NSImage(systemSymbolName: "photo.stack", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "拖入 HEIC 图片或文件夹")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "支持 .heic 和 .heif，可递归扫描文件夹")
        subtitle.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [icon, title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 42),
            icon.heightAnchor.constraint(equalToConstant: 42)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 15, yRadius: 15)
        (targeted ? NSColor.controlAccentColor.withAlphaComponent(0.20) : NSColor.controlAccentColor.withAlphaComponent(0.07)).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(targeted ? 0.9 : 0.45).setStroke()
        path.lineWidth = targeted ? 2.5 : 1.5
        path.setLineDash([8, 5], count: 2, phase: 0)
        path.stroke()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { targeted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { targeted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        targeted = false
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        delegate?.didDrop(urls: urls)
        return true
    }
}

final class ConverterViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, DropAreaDelegate {
    private var files: [URL] = []
    private var customOutputFolder: URL?
    private var lastOutputFolder: URL?
    private let cancellationLock = NSLock()
    private var _cancelRequested = false
    private var cancelRequested: Bool {
        get { cancellationLock.lock(); defer { cancellationLock.unlock() }; return _cancelRequested }
        set { cancellationLock.lock(); _cancelRequested = newValue; cancellationLock.unlock() }
    }

    private let dropArea = DropAreaView()
    private let countLabel = NSTextField(labelWithString: "0 张")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let formatControl = NSSegmentedControl(labels: ["JPG", "PNG"], trackingMode: .selectOne, target: nil, action: nil)
    private let qualitySlider = NSSlider(value: 0.90, minValue: 0.50, maxValue: 1.0, target: nil, action: nil)
    private let qualityValue = NSTextField(labelWithString: "90%")
    private let qualityRow = NSStackView()
    private let locationPopup = NSPopUpButton()
    private let chooseOutputButton = NSButton(title: "选择…", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let currentFileLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "拖入 HEIC 图片或文件夹开始")
    private let convertButton = NSButton(title: "开始转换", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let openOutputButton = NSButton(title: "打开输出目录", target: nil, action: nil)
    private let clearButton = NSButton(title: "清空", target: nil, action: nil)

    override func loadView() {
        view = NSView()
        buildInterface()
    }

    private func buildInterface() {
        let appIcon = NSImageView(image: NSImage(systemSymbolName: "arrow.triangle.2.circlepath.camera.fill", accessibilityDescription: nil)!)
        appIcon.contentTintColor = .controlAccentColor
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([appIcon.widthAnchor.constraint(equalToConstant: 45), appIcon.heightAnchor.constraint(equalToConstant: 45)])
        let heading = NSTextField(labelWithString: "HEIC Batch Converter")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let tagline = NSTextField(labelWithString: "本地批量转换，原图保持不变")
        tagline.textColor = .secondaryLabelColor
        let headingStack = NSStackView(views: [heading, tagline])
        headingStack.orientation = .vertical; headingStack.alignment = .leading; headingStack.spacing = 3
        let header = NSStackView(views: [appIcon, headingStack])
        header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 12

        dropArea.delegate = self
        dropArea.translatesAutoresizingMaskIntoConstraints = false
        dropArea.heightAnchor.constraint(equalToConstant: 150).isActive = true

        let chooseFilesButton = NSButton(title: "选择图片", target: self, action: #selector(chooseFiles))
        let chooseFolderButton = NSButton(title: "选择文件夹", target: self, action: #selector(chooseFolder))
        clearButton.target = self; clearButton.action = #selector(clearFiles)
        let spacer1 = NSView()
        let fileToolbar = NSStackView(views: [chooseFilesButton, chooseFolderButton, spacer1, countLabel, clearButton])
        fileToolbar.orientation = .horizontal; fileToolbar.alignment = .centerY; fileToolbar.spacing = 9

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "待转换文件"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self; tableView.delegate = self
        tableView.rowHeight = 27; tableView.usesAlternatingRowBackgroundColors = true
        scrollView.documentView = tableView; scrollView.hasVerticalScroller = true; scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 145).isActive = true

        formatControl.selectedSegment = 0; formatControl.target = self; formatControl.action = #selector(formatChanged)
        qualitySlider.target = self; qualitySlider.action = #selector(qualityChanged)
        qualityValue.alignment = .right; qualityValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        qualityRow.orientation = .horizontal; qualityRow.alignment = .centerY; qualityRow.spacing = 10
        qualityRow.addArrangedSubview(label("JPG 质量")); qualityRow.addArrangedSubview(qualitySlider); qualityRow.addArrangedSubview(qualityValue)

        locationPopup.addItems(withTitles: ["Converted 子文件夹", "原文件旁边", "指定文件夹"])
        locationPopup.target = self; locationPopup.action = #selector(locationChanged)
        chooseOutputButton.target = self; chooseOutputButton.action = #selector(chooseOutputFolder); chooseOutputButton.isHidden = true
        let settings = NSStackView(views: [formRow(title: "输出格式", controls: [formatControl]), qualityRow, formRow(title: "保存位置", controls: [locationPopup, chooseOutputButton])])
        settings.orientation = .vertical; settings.alignment = .leading; settings.spacing = 12
        settings.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        settings.wantsLayer = true; settings.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; settings.layer?.cornerRadius = 10

        progressBar.isIndeterminate = false; progressBar.minValue = 0; progressBar.maxValue = 1; progressBar.isHidden = true
        currentFileLabel.textColor = .secondaryLabelColor; currentFileLabel.lineBreakMode = .byTruncatingMiddle; currentFileLabel.isHidden = true
        convertButton.target = self; convertButton.action = #selector(startConversion); convertButton.keyEquivalent = "\r"; convertButton.isEnabled = false
        stopButton.target = self; stopButton.action = #selector(stopConversion); stopButton.isHidden = true
        openOutputButton.target = self; openOutputButton.action = #selector(openOutput); openOutputButton.isHidden = true
        let spacer2 = NSView()
        let footer = NSStackView(views: [statusLabel, spacer2, openOutputButton, stopButton, convertButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 9

        let root = NSStackView(views: [header, dropArea, fileToolbar, scrollView, settings, progressBar, currentFileLabel, footer])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 24), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            dropArea.widthAnchor.constraint(equalTo: root.widthAnchor), fileToolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor), settings.widthAnchor.constraint(equalTo: root.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: root.widthAnchor), currentFileLabel.widthAnchor.constraint(equalTo: root.widthAnchor), footer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.widthAnchor.constraint(equalToConstant: 95).isActive = true; return field
    }

    private func formRow(title: String, controls: [NSView]) -> NSStackView {
        let row = NSStackView(); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 10
        row.addArrangedSubview(label(title)); controls.forEach { row.addArrangedSubview($0) }; return row
    }

    func didDrop(urls: [URL]) { add(urls: urls) }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel(); panel.title = "选择 HEIC 图片"; panel.prompt = "添加"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.heic, UTType(filenameExtension: "heif") ?? .image]
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel(); panel.title = "选择包含 HEIC 图片的文件夹"; panel.prompt = "扫描文件夹"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel(); panel.title = "选择输出文件夹"; panel.prompt = "选择"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        if panel.runModal() == .OK { customOutputFolder = panel.url; chooseOutputButton.title = panel.url?.lastPathComponent ?? "选择…"; updateConvertButton() }
    }

    @objc private func clearFiles() {
        files.removeAll(); tableView.reloadData(); countLabel.stringValue = "0 张"; statusLabel.stringValue = "拖入 HEIC 图片或文件夹开始"; openOutputButton.isHidden = true; updateConvertButton()
    }

    @objc private func formatChanged() { qualityRow.isHidden = formatControl.selectedSegment == OutputFormat.png.rawValue }
    @objc private func qualityChanged() { qualityValue.stringValue = "\(Int((qualitySlider.doubleValue * 100).rounded()))%" }
    @objc private func locationChanged() {
        let custom = locationPopup.indexOfSelectedItem == OutputLocation.custom.rawValue; chooseOutputButton.isHidden = !custom
        if custom && customOutputFolder == nil { chooseOutputFolder() }; updateConvertButton()
    }
    @objc private func stopConversion() { cancelRequested = true; statusLabel.stringValue = "正在停止…" }
    @objc private func openOutput() { if let lastOutputFolder { NSWorkspace.shared.open(lastOutputFolder) } }

    private func add(urls: [URL]) {
        let discovered = Self.collectHEICFiles(from: urls); var paths = Set(files.map { $0.standardizedFileURL.path })
        for file in discovered where paths.insert(file.standardizedFileURL.path).inserted { files.append(file) }
        files.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }; tableView.reloadData()
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        countLabel.stringValue = "\(files.count) 张 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        statusLabel.stringValue = files.isEmpty ? "没有找到 HEIC/HEIF 图片" : "已添加 \(files.count) 张图片"
        openOutputButton.isHidden = true; updateConvertButton()
    }

    private func updateConvertButton() {
        let customReady = locationPopup.indexOfSelectedItem != OutputLocation.custom.rawValue || customOutputFolder != nil
        convertButton.isEnabled = !files.isEmpty && customReady
    }

    @objc private func startConversion() {
        guard !files.isEmpty else { return }
        let inputFiles = files; let format = OutputFormat(rawValue: formatControl.selectedSegment) ?? .jpeg
        let quality = qualitySlider.doubleValue; let location = OutputLocation(rawValue: locationPopup.indexOfSelectedItem) ?? .subfolder; let customFolder = customOutputFolder
        cancelRequested = false; setConverting(true); progressBar.doubleValue = 0; statusLabel.stringValue = "正在转换…"; openOutputButton.isHidden = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }; var succeeded = 0; var failures: [(String, String)] = []; var firstOutputFolder: URL?
            for (index, file) in inputFiles.enumerated() {
                if self.cancelRequested { break }
                DispatchQueue.main.async { self.currentFileLabel.stringValue = file.lastPathComponent }
                do {
                    let directory: URL
                    switch location {
                    case .besideOriginal: directory = file.deletingLastPathComponent()
                    case .subfolder: directory = file.deletingLastPathComponent().appendingPathComponent("Converted", isDirectory: true)
                    case .custom: guard let customFolder else { throw ConversionError.missingOutputFolder }; directory = customFolder
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let output = Self.availableOutputURL(for: file, in: directory, extension: format.fileExtension)
                    try Self.convertImage(file, to: output, format: format, jpegQuality: quality)
                    if firstOutputFolder == nil { firstOutputFolder = directory }; succeeded += 1
                } catch { failures.append((file.lastPathComponent, error.localizedDescription)) }
                let progress = Double(index + 1) / Double(inputFiles.count); DispatchQueue.main.async { self.progressBar.doubleValue = progress }
            }
            DispatchQueue.main.async {
                self.lastOutputFolder = firstOutputFolder; self.setConverting(false); self.currentFileLabel.stringValue = ""; self.openOutputButton.isHidden = firstOutputFolder == nil
                if self.cancelRequested { self.statusLabel.stringValue = "已停止：成功 \(succeeded) 张" }
                else if failures.isEmpty { self.statusLabel.stringValue = "转换完成：成功 \(succeeded) 张" }
                else { self.statusLabel.stringValue = "转换完成：成功 \(succeeded) 张，失败 \(failures.count) 张"; self.showFailures(failures) }
            }
        }
    }

    private func setConverting(_ converting: Bool) {
        progressBar.isHidden = !converting; currentFileLabel.isHidden = !converting; convertButton.isHidden = converting; stopButton.isHidden = !converting
        clearButton.isEnabled = !converting; tableView.isEnabled = !converting; formatControl.isEnabled = !converting; qualitySlider.isEnabled = !converting; locationPopup.isEnabled = !converting
    }

    private func showFailures(_ failures: [(String, String)]) {
        let alert = NSAlert(); alert.messageText = "部分文件转换失败"; alert.alertStyle = .warning
        alert.informativeText = failures.prefix(12).map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        if failures.count > 12 { alert.informativeText += "\n…另有 \(failures.count - 12) 个文件" }; alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView(); cell.identifier = id; let text = NSTextField(labelWithString: ""); text.translatesAutoresizingMaskIntoConstraints = false; text.lineBreakMode = .byTruncatingMiddle
            cell.textField = text; cell.addSubview(text); NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8), text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]); return cell
        }()
        cell.textField?.stringValue = files[row].path; return cell
    }

    private static func collectHEICFiles(from urls: [URL]) -> [URL] {
        var result: [URL] = []; let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in true })
                while let file = enumerator?.nextObject() as? URL { let child = try? file.resourceValues(forKeys: keys); if child?.isRegularFile == true, child?.isSymbolicLink != true, isHEIC(file) { result.append(file) } }
            } else if values?.isRegularFile == true, isHEIC(url) { result.append(url) }
        }; return result
    }

    private static func isHEIC(_ url: URL) -> Bool { ["heic", "heif"].contains(url.pathExtension.lowercased()) }
    private static func availableOutputURL(for input: URL, in directory: URL, extension ext: String) -> URL {
        let base = input.deletingPathExtension().lastPathComponent; var output = directory.appendingPathComponent(base).appendingPathExtension(ext); var number = 2
        while FileManager.default.fileExists(atPath: output.path) { output = directory.appendingPathComponent("\(base)-\(number)").appendingPathExtension(ext); number += 1 }; return output
    }
    private static func convertImage(_ input: URL, to output: URL, format: OutputFormat, jpegQuality: Double) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw ConversionError.cannotRead }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ConversionError.cannotDecode }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, format.typeIdentifier, 1, nil) else { throw ConversionError.cannotCreateOutput }
        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: output); throw ConversionError.cannotWrite }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentViewController: ConverterViewController()); window.title = "HEIC Batch Converter"; window.setContentSize(NSSize(width: 760, height: 720)); window.minSize = NSSize(width: 680, height: 650); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
