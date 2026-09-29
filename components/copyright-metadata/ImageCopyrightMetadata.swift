import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum OutputLocation: Int { case inPlace = 0, subfolder = 1, besideOriginal = 2, custom = 3 }

enum MetadataError: LocalizedError {
    case cannotRead
    case unknownFormat
    case unsupportedFormat
    case cannotCreateOutput
    case cannotWrite(String)
    case missingOutputFolder

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "无法读取图片"
        case .unknownFormat: return "无法识别图片格式"
        case .unsupportedFormat: return "该图片格式不支持写入元数据"
        case .cannotCreateOutput: return "无法创建输出文件"
        case .cannotWrite(let reason): return reason.isEmpty ? "写入元数据失败" : "写入元数据失败：\(reason)"
        case .missingOutputFolder: return "未选择输出文件夹"
        }
    }
}

struct MetadataWriter {
    static let defaultCreator = "Bruce"
    static let defaultCopyright = "Copyright © Bruce. All rights reserved."

    static func write(input: URL, output: URL, creator: String, copyright: String) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else { throw MetadataError.cannotRead }
        guard let type = CGImageSourceGetType(source) else { throw MetadataError.unknownFormat }

        let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        guard writableTypes.contains(type as String) else { throw MetadataError.unsupportedFormat }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type, CGImageSourceGetCount(source), nil) else {
            throw MetadataError.cannotCreateOutput
        }

        let metadata = makeMetadata(creator: creator, copyright: copyright)
        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
            kCGImageDestinationPreserveGainMap: true
        ]

        var unmanagedError: Unmanaged<CFError>?
        let success = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &unmanagedError)
        if !success {
            try? FileManager.default.removeItem(at: output)
            let reason = unmanagedError?.takeRetainedValue().localizedDescription ?? ""
            throw MetadataError.cannotWrite(reason)
        }
    }

    private static func makeMetadata(creator: String, copyright: String) -> CGMutableImageMetadata {
        let metadata = CGImageMetadataCreateMutable()
        var registrationError: Unmanaged<CFError>?
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceDublinCore, kCGImageMetadataPrefixDublinCore, &registrationError)
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop, &registrationError)
        _ = CGImageMetadataRegisterNamespaceForPrefix(metadata, kCGImageMetadataNamespaceXMPRights, kCGImageMetadataPrefixXMPRights, &registrationError)

        func setTag(namespace: CFString, prefix: CFString, name: String, value: String) {
            guard let tag = CGImageMetadataTagCreate(namespace, prefix, name as CFString, .string, value as CFString) else { return }
            _ = CGImageMetadataSetTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString, tag)
        }

        setTag(namespace: kCGImageMetadataNamespaceDublinCore, prefix: kCGImageMetadataPrefixDublinCore, name: "creator", value: creator)
        setTag(namespace: kCGImageMetadataNamespaceDublinCore, prefix: kCGImageMetadataPrefixDublinCore, name: "rights", value: copyright)
        setTag(namespace: kCGImageMetadataNamespaceDublinCore, prefix: kCGImageMetadataPrefixDublinCore, name: "description", value: copyright)
        setTag(namespace: kCGImageMetadataNamespacePhotoshop, prefix: kCGImageMetadataPrefixPhotoshop, name: "Credit", value: creator)
        setTag(namespace: kCGImageMetadataNamespaceXMPRights, prefix: kCGImageMetadataPrefixXMPRights, name: "UsageTerms", value: copyright)

        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCByline, creator as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice, copyright as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, copyright as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCredit, creator as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, creator as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, copyright as CFString)
        _ = CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, copyright as CFString)
        return metadata
    }

    static func verify(url: URL, expectedCreator: String, expectedCopyright: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let xmpData = CGImageMetadataCreateXMPData(metadata, nil),
              let xmp = String(data: xmpData as Data, encoding: .utf8) else { return false }
        return xmp.contains(expectedCreator) && xmp.contains(expectedCopyright)
    }

    static func writeInPlace(file: URL, creator: String, copyright: String) throws {
        let fileManager = FileManager.default
        let directory = file.deletingLastPathComponent()
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        let temporaryName = ".\(base).metadata-\(UUID().uuidString)"
        let temporaryURL = directory.appendingPathComponent(temporaryName).appendingPathExtension(ext)
        let originalAttributes = try? fileManager.attributesOfItem(atPath: file.path)
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try write(input: file, output: temporaryURL, creator: creator, copyright: copyright)
        guard verify(url: temporaryURL, expectedCreator: creator, expectedCopyright: copyright) else {
            throw MetadataError.cannotWrite("临时文件校验未通过，原文件未修改")
        }

        _ = try fileManager.replaceItemAt(file, withItemAt: temporaryURL, backupItemName: nil, options: [])
        if let permissions = originalAttributes?[.posixPermissions] {
            try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path)
        }
        guard verify(url: file, expectedCreator: creator, expectedCopyright: copyright) else {
            throw MetadataError.cannotWrite("替换后校验未通过")
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

        let icon = NSImageView(image: NSImage(systemSymbolName: "signature", accessibilityDescription: nil)!)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "拖入图片或文件夹")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "支持 JPG、PNG、HEIC、HEIF 和 TIFF，可递归扫描文件夹")
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

final class MetadataViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, DropAreaDelegate {
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
    private let creatorField = NSTextField(string: MetadataWriter.defaultCreator)
    private let copyrightField = NSTextField(string: MetadataWriter.defaultCopyright)
    private let locationPopup = NSPopUpButton()
    private let chooseOutputButton = NSButton(title: "选择…", target: nil, action: nil)
    private let progressBar = NSProgressIndicator()
    private let currentFileLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "拖入图片或文件夹开始")
    private let writeButton = NSButton(title: "开始写入", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let openOutputButton = NSButton(title: "打开输出目录", target: nil, action: nil)
    private let clearButton = NSButton(title: "清空", target: nil, action: nil)

    override func loadView() {
        view = NSView()
        buildInterface()
    }

    private func buildInterface() {
        let appIcon = NSImageView(image: NSImage(systemSymbolName: "photo.badge.checkmark.fill", accessibilityDescription: nil)!)
        appIcon.contentTintColor = .controlAccentColor
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appIcon.widthAnchor.constraint(equalToConstant: 45),
            appIcon.heightAnchor.constraint(equalToConstant: 45)
        ])

        let heading = NSTextField(labelWithString: "图片版权信息批量写入")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let tagline = NSTextField(labelWithString: "写入图片元数据，不在画面上显示文字")
        tagline.textColor = .secondaryLabelColor
        let headingStack = NSStackView(views: [heading, tagline])
        headingStack.orientation = .vertical
        headingStack.alignment = .leading
        headingStack.spacing = 3
        let header = NSStackView(views: [appIcon, headingStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        dropArea.delegate = self
        dropArea.translatesAutoresizingMaskIntoConstraints = false
        dropArea.heightAnchor.constraint(equalToConstant: 140).isActive = true

        let chooseFilesButton = NSButton(title: "选择图片", target: self, action: #selector(chooseFiles))
        let chooseFolderButton = NSButton(title: "选择文件夹", target: self, action: #selector(chooseFolder))
        clearButton.target = self
        clearButton.action = #selector(clearFiles)
        let spacer1 = NSView()
        let fileToolbar = NSStackView(views: [chooseFilesButton, chooseFolderButton, spacer1, countLabel, clearButton])
        fileToolbar.orientation = .horizontal
        fileToolbar.alignment = .centerY
        fileToolbar.spacing = 9

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "待处理文件"
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 27
        tableView.usesAlternatingRowBackgroundColors = true
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.heightAnchor.constraint(equalToConstant: 135).isActive = true

        creatorField.placeholderString = "作者"
        copyrightField.placeholderString = "版权声明"
        creatorField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        copyrightField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        locationPopup.addItems(withTitles: ["直接修改原文件（不生成副本）", "已添加版权信息 子文件夹", "原文件旁边", "指定文件夹"])
        locationPopup.target = self
        locationPopup.action = #selector(locationChanged)
        chooseOutputButton.target = self
        chooseOutputButton.action = #selector(chooseOutputFolder)
        chooseOutputButton.isHidden = true

        let settings = NSStackView(views: [
            formRow(title: "作者", controls: [creatorField]),
            formRow(title: "版权声明", controls: [copyrightField]),
            formRow(title: "保存位置", controls: [locationPopup, chooseOutputButton])
        ])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 12
        settings.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        settings.wantsLayer = true
        settings.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        settings.layer?.cornerRadius = 10

        let note = NSTextField(wrappingLabelWithString: "写入字段：XMP Creator / Rights / Description、IPTC Copyright / Credit、TIFF/PNG Copyright。直接修改时会先校验临时文件，再安全替换原文件。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        currentFileLabel.textColor = .secondaryLabelColor
        currentFileLabel.lineBreakMode = .byTruncatingMiddle
        currentFileLabel.isHidden = true

        writeButton.target = self
        writeButton.action = #selector(startWriting)
        writeButton.keyEquivalent = "\r"
        writeButton.isEnabled = false
        stopButton.target = self
        stopButton.action = #selector(stopWriting)
        stopButton.isHidden = true
        openOutputButton.target = self
        openOutputButton.action = #selector(openOutput)
        openOutputButton.isHidden = true

        let spacer2 = NSView()
        let footer = NSStackView(views: [statusLabel, spacer2, openOutputButton, stopButton, writeButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 9

        let root = NSStackView(views: [header, dropArea, fileToolbar, scrollView, settings, note, progressBar, currentFileLabel, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 13
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24),
            dropArea.widthAnchor.constraint(equalTo: root.widthAnchor),
            fileToolbar.widthAnchor.constraint(equalTo: root.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor),
            settings.widthAnchor.constraint(equalTo: root.widthAnchor),
            note.widthAnchor.constraint(equalTo: root.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            currentFileLabel.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        return field
    }

    private func formRow(title: String, controls: [NSView]) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.addArrangedSubview(label(title))
        controls.forEach { row.addArrangedSubview($0) }
        return row
    }

    func didDrop(urls: [URL]) { add(urls: urls) }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择图片"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, UTType(filenameExtension: "heif") ?? .image]
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择包含图片的文件夹"
        panel.prompt = "扫描文件夹"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择输出文件夹"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK {
            customOutputFolder = panel.url
            chooseOutputButton.title = panel.url?.lastPathComponent ?? "选择…"
            updateWriteButton()
        }
    }

    @objc private func clearFiles() {
        files.removeAll()
        tableView.reloadData()
        countLabel.stringValue = "0 张"
        statusLabel.stringValue = "拖入图片或文件夹开始"
        openOutputButton.isHidden = true
        updateWriteButton()
    }

    @objc private func locationChanged() {
        let custom = locationPopup.indexOfSelectedItem == OutputLocation.custom.rawValue
        chooseOutputButton.isHidden = !custom
        if custom && customOutputFolder == nil { chooseOutputFolder() }
        updateWriteButton()
    }

    @objc private func stopWriting() {
        cancelRequested = true
        statusLabel.stringValue = "正在停止…"
    }

    @objc private func openOutput() {
        if let lastOutputFolder { NSWorkspace.shared.open(lastOutputFolder) }
    }

    private func add(urls: [URL]) {
        let discovered = Self.collectImageFiles(from: urls)
        var paths = Set(files.map { $0.standardizedFileURL.path })
        for file in discovered where paths.insert(file.standardizedFileURL.path).inserted { files.append(file) }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        tableView.reloadData()
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        countLabel.stringValue = "\(files.count) 张 · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        statusLabel.stringValue = files.isEmpty ? "没有找到支持的图片" : "已添加 \(files.count) 张图片"
        openOutputButton.isHidden = true
        updateWriteButton()
    }

    private func updateWriteButton() {
        let customReady = locationPopup.indexOfSelectedItem != OutputLocation.custom.rawValue || customOutputFolder != nil
        writeButton.isEnabled = !files.isEmpty && customReady && !creatorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !copyrightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc private func startWriting() {
        guard !files.isEmpty else { return }
        let inputFiles = files
        let creator = creatorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyright = copyrightField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = OutputLocation(rawValue: locationPopup.indexOfSelectedItem) ?? .inPlace
        let customFolder = customOutputFolder
        guard !creator.isEmpty, !copyright.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "请填写作者和版权声明"
            alert.runModal()
            return
        }

        cancelRequested = false
        setWriting(true)
        progressBar.doubleValue = 0
        statusLabel.stringValue = "正在写入图片信息…"
        openOutputButton.isHidden = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var succeeded = 0
            var failures: [(String, String)] = []
            var firstOutputFolder: URL?

            for (index, file) in inputFiles.enumerated() {
                if self.cancelRequested { break }
                DispatchQueue.main.async { self.currentFileLabel.stringValue = file.lastPathComponent }
                do {
                    let directory: URL
                    switch location {
                    case .inPlace:
                        directory = file.deletingLastPathComponent()
                    case .besideOriginal:
                        directory = file.deletingLastPathComponent()
                    case .subfolder:
                        directory = file.deletingLastPathComponent().appendingPathComponent("已添加版权信息", isDirectory: true)
                    case .custom:
                        guard let customFolder else { throw MetadataError.missingOutputFolder }
                        directory = customFolder
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    if location == .inPlace {
                        try MetadataWriter.writeInPlace(file: file, creator: creator, copyright: copyright)
                    } else {
                        let output = Self.availableOutputURL(for: file, in: directory, besideOriginal: location == .besideOriginal)
                        try MetadataWriter.write(input: file, output: output, creator: creator, copyright: copyright)
                        guard MetadataWriter.verify(url: output, expectedCreator: creator, expectedCopyright: copyright) else {
                            try? FileManager.default.removeItem(at: output)
                            throw MetadataError.cannotWrite("写入后校验未通过")
                        }
                    }
                    if firstOutputFolder == nil { firstOutputFolder = directory }
                    succeeded += 1
                } catch {
                    failures.append((file.lastPathComponent, error.localizedDescription))
                }

                let progress = Double(index + 1) / Double(inputFiles.count)
                DispatchQueue.main.async { self.progressBar.doubleValue = progress }
            }

            DispatchQueue.main.async {
                self.lastOutputFolder = firstOutputFolder
                self.setWriting(false)
                self.currentFileLabel.stringValue = ""
                self.openOutputButton.isHidden = firstOutputFolder == nil
                if self.cancelRequested {
                    self.statusLabel.stringValue = "已停止：成功 \(succeeded) 张"
                } else if failures.isEmpty {
                    self.statusLabel.stringValue = "写入完成：成功 \(succeeded) 张"
                } else {
                    self.statusLabel.stringValue = "写入完成：成功 \(succeeded) 张，失败 \(failures.count) 张"
                    self.showFailures(failures)
                }
            }
        }
    }

    private func setWriting(_ writing: Bool) {
        progressBar.isHidden = !writing
        currentFileLabel.isHidden = !writing
        writeButton.isHidden = writing
        stopButton.isHidden = !writing
        clearButton.isEnabled = !writing
        tableView.isEnabled = !writing
        creatorField.isEnabled = !writing
        copyrightField.isEnabled = !writing
        locationPopup.isEnabled = !writing
        chooseOutputButton.isEnabled = !writing
    }

    private func showFailures(_ failures: [(String, String)]) {
        let alert = NSAlert()
        alert.messageText = "部分文件写入失败"
        alert.alertStyle = .warning
        alert.informativeText = failures.prefix(12).map { "\($0.0)：\($0.1)" }.joined(separator: "\n")
        if failures.count > 12 { alert.informativeText += "\n…另有 \(failures.count - 12) 个文件" }
        alert.runModal()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? {
            let cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.textField = text
            cell.addSubview(text)
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }()
        cell.textField?.stringValue = files[row].path
        return cell
    }

    private static func collectImageFiles(from urls: [URL]) -> [URL] {
        var result: [URL] = []
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
        for url in urls {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, _ in true }
                )
                while let file = enumerator?.nextObject() as? URL {
                    let child = try? file.resourceValues(forKeys: keys)
                    if child?.isRegularFile == true, child?.isSymbolicLink != true, child?.isHidden != true, isSupportedImage(file) {
                        result.append(file)
                    }
                }
            } else if values?.isRegularFile == true, isSupportedImage(url) {
                result.append(url)
            }
        }
        return result
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"].contains(url.pathExtension.lowercased())
    }

    private static func availableOutputURL(for input: URL, in directory: URL, besideOriginal: Bool) -> URL {
        let ext = input.pathExtension
        let originalBase = input.deletingPathExtension().lastPathComponent
        let base = besideOriginal ? "\(originalBase)_版权信息" : originalBase
        var output = directory.appendingPathComponent(base).appendingPathExtension(ext)
        var number = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = directory.appendingPathComponent("\(base)-\(number)").appendingPathExtension(ext)
            number += 1
        }
        return output
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentViewController: MetadataViewController())
        window.title = "图片版权信息批量写入"
        window.setContentSize(NSSize(width: 780, height: 745))
        window.minSize = NSSize(width: 700, height: 680)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-in-place" {
    do {
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        try MetadataWriter.writeInPlace(file: input, creator: MetadataWriter.defaultCreator, copyright: MetadataWriter.defaultCopyright)
        print("OK")
    } catch {
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--write-metadata" {
    do {
        let input = URL(fileURLWithPath: CommandLine.arguments[2])
        let output = URL(fileURLWithPath: CommandLine.arguments[3])
        try MetadataWriter.write(input: input, output: output, creator: MetadataWriter.defaultCreator, copyright: MetadataWriter.defaultCopyright)
        guard MetadataWriter.verify(url: output, expectedCreator: MetadataWriter.defaultCreator, expectedCopyright: MetadataWriter.defaultCopyright) else {
            throw MetadataError.cannotWrite("写入后校验未通过")
        }
        print("OK")
    } catch {
        fputs("ERROR: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
