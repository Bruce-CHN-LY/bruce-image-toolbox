import AppKit
import Foundation

private let supportedImageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "gif", "bmp", "avif"
]

enum RenameError: LocalizedError {
    case noFiles
    case multipleFolders
    case invalidBaseName
    case targetExists(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFiles:
            return "请先拖入需要重命名的图片。"
        case .multipleFolders:
            return "一次只能处理同一个文件夹里的图片。"
        case .invalidBaseName:
            return "请输入有效名称，名称中不能包含 /、: 或换行。"
        case .targetExists(let name):
            return "目标文件已经存在：\(name)"
        case .operationFailed(let message):
            return message
        }
    }
}

enum WebPMode: Int {
    case lossless = 0
    case photoQuality85 = 1

    var cwebpArguments: [String] {
        switch self {
        case .lossless:
            return ["-lossless"]
        case .photoQuality85:
            return ["-q", "85"]
        }
    }

    var displayName: String {
        switch self {
        case .lossless:
            return "无损"
        case .photoQuality85:
            return "照片质量 85"
        }
    }
}

enum WebPError: LocalizedError {
    case cwebpNotInstalled
    case unsupportedInput
    case targetExists(String)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .cwebpNotInstalled:
            return "没有找到 cwebp。请先在终端运行：brew install webp"
        case .unsupportedInput:
            return "所选文件中没有可转换的 PNG、JPG、JPEG、TIF 或 TIFF 图片。"
        case .targetExists(let name):
            return "WebP 文件已经存在：webp/\(name)。为避免覆盖，处理已停止。"
        case .conversionFailed(let message):
            return "WebP 转换失败：\(message)"
        }
    }
}

struct RenameService {
    private struct RenameItem {
        let original: URL
        let temporary: URL
        let destination: URL
    }

    static func normalizedBaseName(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !value.contains("/"),
              !value.contains(":"),
              !value.contains("\n"),
              !value.contains("\r") else {
            throw RenameError.invalidBaseName
        }
        return value
    }

    static func sortedImageURLs(from inputURLs: [URL]) throws -> [URL] {
        let fileManager = FileManager.default
        var collected: [URL] = []

        for inputURL in inputURLs {
            let url = inputURL.standardizedFileURL
            var isDirectory: ObjCBool = false

            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                // 文件夹只读取当前层级，避免误改子文件夹内容。
                let children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                collected.append(contentsOf: children.filter(isSupportedImage))
            } else if isSupportedImage(url) {
                collected.append(url)
            }
        }

        let uniqueURLs = Dictionary(
            collected.map { ($0.standardizedFileURL.path, $0.standardizedFileURL) },
            uniquingKeysWith: { first, _ in first }
        ).values

        let sorted = uniqueURLs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        guard !sorted.isEmpty else {
            throw RenameError.noFiles
        }

        let folders = Set(sorted.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard folders.count == 1 else {
            throw RenameError.multipleFolders
        }

        return sorted
    }

    static func previewName(for file: URL, baseName: String, index: Int) -> String {
        let fileExtension = file.pathExtension
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return "\(baseName)-\(index + 1)\(suffix)"
    }

    static func destinationURLs(for files: [URL], baseName input: String) throws -> [URL] {
        let baseName = try normalizedBaseName(input)
        return files.enumerated().map { index, source in
            source.deletingLastPathComponent().appendingPathComponent(
                previewName(for: source, baseName: baseName, index: index)
            )
        }
    }

    static func rename(files: [URL], baseName input: String) throws -> [URL] {
        guard !files.isEmpty else {
            throw RenameError.noFiles
        }

        let baseName = try normalizedBaseName(input)
        let fileManager = FileManager.default
        let sourcePaths = Set(files.map { $0.standardizedFileURL.path })

        let plan: [RenameItem] = files.enumerated().map { index, source in
            let folder = source.deletingLastPathComponent()
            let destinationName = previewName(for: source, baseName: baseName, index: index)
            let destination = folder.appendingPathComponent(destinationName)
            let temporaryName = ".bruce-rename-\(UUID().uuidString).tmp"
            let temporary = folder.appendingPathComponent(temporaryName)
            return RenameItem(original: source, temporary: temporary, destination: destination)
        }

        // 在改名前先检查目标，绝不覆盖未选中的现有文件。
        for item in plan {
            if fileManager.fileExists(atPath: item.destination.path),
               !sourcePaths.contains(item.destination.standardizedFileURL.path) {
                throw RenameError.targetExists(item.destination.lastPathComponent)
            }
        }

        var movedToTemporary: [RenameItem] = []

        do {
            // 第一阶段先使用随机临时名，避免名称互换或编号变化时发生冲突。
            for item in plan {
                try fileManager.moveItem(at: item.original, to: item.temporary)
                movedToTemporary.append(item)
            }
        } catch {
            for item in movedToTemporary.reversed() {
                try? fileManager.moveItem(at: item.temporary, to: item.original)
            }
            throw RenameError.operationFailed("无法准备重命名：\(error.localizedDescription)")
        }

        var completed: [RenameItem] = []

        do {
            // 第二阶段再统一写入最终名称。
            for item in plan {
                try fileManager.moveItem(at: item.temporary, to: item.destination)
                completed.append(item)
            }
        } catch {
            // 失败时尽可能恢复全部原文件名。
            for item in completed.reversed() {
                try? fileManager.moveItem(at: item.destination, to: item.original)
            }
            for item in plan where !completed.contains(where: { $0.temporary == item.temporary }) {
                if fileManager.fileExists(atPath: item.temporary.path) {
                    try? fileManager.moveItem(at: item.temporary, to: item.original)
                }
            }
            throw RenameError.operationFailed("重命名失败，已尝试恢复原文件：\(error.localizedDescription)")
        }

        return plan.map(\.destination)
    }

    private static func isSupportedImage(_ url: URL) -> Bool {
        supportedImageExtensions.contains(url.pathExtension.lowercased())
    }
}

struct WebPService {
    private static let inputExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tif", "tiff"
    ]

    static func executableURL() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/cwebp",
            "/usr/local/bin/cwebp"
        ]

        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func convertibleFiles(from files: [URL]) -> [URL] {
        files.filter { inputExtensions.contains($0.pathExtension.lowercased()) }
    }

    static func outputURLs(for files: [URL]) throws -> [URL] {
        let convertible = convertibleFiles(from: files)
        guard !convertible.isEmpty else {
            throw WebPError.unsupportedInput
        }

        return convertible.map { source in
            let outputFolder = source.deletingLastPathComponent().appendingPathComponent("webp")
            let outputName = source.deletingPathExtension().lastPathComponent + ".webp"
            return outputFolder.appendingPathComponent(outputName)
        }
    }

    static func preflight(files: [URL]) throws {
        guard executableURL() != nil else {
            throw WebPError.cwebpNotInstalled
        }

        let fileManager = FileManager.default
        for outputURL in try outputURLs(for: files) {
            if fileManager.fileExists(atPath: outputURL.path) {
                throw WebPError.targetExists(outputURL.lastPathComponent)
            }
        }
    }

    static func convert(files: [URL], mode: WebPMode) throws -> [URL] {
        guard let executable = executableURL() else {
            throw WebPError.cwebpNotInstalled
        }

        let fileManager = FileManager.default
        let convertible = convertibleFiles(from: files)
        let outputs = try outputURLs(for: files)

        guard let firstFile = convertible.first else {
            throw WebPError.unsupportedInput
        }

        let outputFolder = firstFile.deletingLastPathComponent().appendingPathComponent("webp")
        try fileManager.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        var createdOutputs: [URL] = []

        do {
            for (source, destination) in zip(convertible, outputs) {
                let temporary = outputFolder.appendingPathComponent(
                    ".bruce-webp-\(UUID().uuidString).webp"
                )

                let process = Process()
                process.executableURL = executable
                process.arguments = mode.cwebpArguments + [
                    "-mt",
                    "-quiet",
                    source.path,
                    "-o",
                    temporary.path
                ]

                let errorPipe = Pipe()
                process.standardError = errorPipe

                try process.run()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    try? fileManager.removeItem(at: temporary)
                    throw WebPError.conversionFailed(
                        message?.isEmpty == false ? message! : source.lastPathComponent
                    )
                }

                try fileManager.moveItem(at: temporary, to: destination)
                createdOutputs.append(destination)
            }
        } catch {
            // 转换不完整时删除本次新文件，原图始终保留。
            for output in createdOutputs {
                try? fileManager.removeItem(at: output)
            }
            throw error
        }

        return createdOutputs
    }
}

protocol ImageDropViewDelegate: AnyObject {
    func imageDropView(_ view: ImageDropView, received urls: [URL])
}

final class ImageDropView: NSView {
    weak var delegate: ImageDropViewDelegate?
    private let messageLabel = NSTextField(labelWithString: "把图片或文件夹拖到这里")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.06).cgColor

        messageLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        layer?.borderColor = NSColor.systemTeal.cgColor
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.12).cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        restoreAppearance()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { restoreAppearance() }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        guard let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ) else {
            return false
        }

        let urls = objects.compactMap { object -> URL? in
            guard let nsURL = object as? NSURL else { return nil }
            return nsURL as URL
        }

        guard !urls.isEmpty else { return false }
        delegate?.imageDropView(self, received: urls)
        return true
    }

    private func restoreAppearance() {
        layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.45).cgColor
        layer?.backgroundColor = NSColor.systemTeal.withAlphaComponent(0.06).cgColor
    }
}

final class RenameViewController: NSViewController,
                                  ImageDropViewDelegate,
                                  NSTableViewDataSource,
                                  NSTableViewDelegate,
                                  NSTextFieldDelegate {
    private let dropView = ImageDropView()
    private let baseNameField = NSTextField()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "尚未添加图片")
    private let convertCheckbox = NSButton(
        checkboxWithTitle: "重命名后同时生成 WebP",
        target: nil,
        action: nil
    )
    private let conversionModePopup = NSPopUpButton()
    private let cwebpStatusLabel = NSTextField(labelWithString: "")
    private let renameButton = NSButton(title: "开始处理", target: nil, action: nil)
    private var files: [URL] = []

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 590))
        buildInterface()
    }

    private func buildInterface() {
        dropView.delegate = self
        dropView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "图片批量编号重命名")
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)

        let subtitleLabel = NSTextField(labelWithString: "按原文件名自然排序，生成“名称-1”到“名称-n”，并保留扩展名。")
        subtitleLabel.textColor = .secondaryLabelColor

        let chooseButton = NSButton(title: "选择图片或文件夹", target: self, action: #selector(chooseFiles))
        let clearButton = NSButton(title: "清空", target: self, action: #selector(clearFiles))

        let buttonRow = NSStackView(views: [chooseButton, clearButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let nameLabel = NSTextField(labelWithString: "统一名称")
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        baseNameField.placeholderString = "例如：1P12S58AH-FPC&CCS"
        baseNameField.delegate = self
        baseNameField.font = .systemFont(ofSize: 15)

        let nameRow = NSStackView(views: [nameLabel, baseNameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 12
        nameLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true

        convertCheckbox.target = self
        convertCheckbox.action = #selector(conversionOptionChanged)
        convertCheckbox.state = .off

        conversionModePopup.addItems(withTitles: [
            "无损：透明背景、文字和产品图",
            "质量 85：照片文件更小"
        ])
        conversionModePopup.selectItem(at: 0)
        conversionModePopup.isEnabled = false

        if WebPService.executableURL() != nil {
            cwebpStatusLabel.stringValue = "cwebp 已安装 · 输出到同目录的 webp 文件夹"
            cwebpStatusLabel.textColor = .secondaryLabelColor
        } else {
            cwebpStatusLabel.stringValue = "未安装 cwebp · 请运行 brew install webp"
            cwebpStatusLabel.textColor = .systemOrange
        }

        let conversionTopRow = NSStackView(views: [convertCheckbox, conversionModePopup])
        conversionTopRow.orientation = .horizontal
        conversionTopRow.alignment = .centerY
        conversionTopRow.spacing = 14

        let conversionStack = NSStackView(views: [conversionTopRow, cwebpStatusLabel])
        conversionStack.orientation = .vertical
        conversionStack.alignment = .leading
        conversionStack.spacing = 5

        let currentColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("current"))
        currentColumn.title = "当前文件名"
        currentColumn.width = 310

        let newColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("new"))
        newColumn.title = "重命名预览"
        newColumn.width = 310

        tableView.addTableColumn(currentColumn)
        tableView.addTableColumn(newColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 26

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        statusLabel.textColor = .secondaryLabelColor

        renameButton.target = self
        renameButton.action = #selector(renameFiles)
        renameButton.bezelStyle = .rounded
        renameButton.keyEquivalent = "\r"
        renameButton.isEnabled = false

        let footer = NSStackView(views: [statusLabel, NSView(), renameButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            dropView,
            buttonRow,
            nameRow,
            conversionStack,
            scrollView,
            footer
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dropView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            dropView.heightAnchor.constraint(equalToConstant: 92),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            conversionStack.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            baseNameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])
    }

    func imageDropView(_ view: ImageDropView, received urls: [URL]) {
        load(urls: urls)
    }

    func load(urls: [URL]) {
        do {
            files = try RenameService.sortedImageURLs(from: urls)
            tableView.reloadData()
            updateState(message: "已添加 \(files.count) 张图片，顺序按当前文件名排列")
        } catch {
            show(error: error)
        }
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择图片或图片文件夹"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            load(urls: panel.urls)
        }
    }

    @objc private func clearFiles() {
        files = []
        tableView.reloadData()
        updateState(message: "尚未添加图片")
    }

    @objc private func conversionOptionChanged() {
        conversionModePopup.isEnabled = convertCheckbox.state == .on
    }

    @objc private func renameFiles() {
        do {
            let baseName = try RenameService.normalizedBaseName(baseNameField.stringValue)
            let shouldConvert = convertCheckbox.state == .on
            let futureFiles = try RenameService.destinationURLs(for: files, baseName: baseName)

            // 在修改原文件前完成全部 WebP 前置检查。
            if shouldConvert {
                try WebPService.preflight(files: futureFiles)
            }

            let confirmation = NSAlert()
            confirmation.messageText = "确认处理 \(files.count) 张图片？"

            var confirmationText = "原图将依次命名为 \(baseName)-1 到 \(baseName)-\(files.count)，扩展名保持不变。"
            if shouldConvert {
                let mode = WebPMode(rawValue: conversionModePopup.indexOfSelectedItem) ?? .lossless
                let webpCount = WebPService.convertibleFiles(from: futureFiles).count
                confirmationText += "\n同时使用“\(mode.displayName)”生成 \(webpCount) 张 WebP，保存到 webp 文件夹。"
            }

            confirmation.informativeText = confirmationText
            confirmation.addButton(withTitle: "确认处理")
            confirmation.addButton(withTitle: "取消")
            confirmation.alertStyle = .informational

            guard confirmation.runModal() == .alertFirstButtonReturn else {
                return
            }

            files = try RenameService.rename(files: files, baseName: baseName)

            var webpCount = 0
            if shouldConvert {
                let mode = WebPMode(rawValue: conversionModePopup.indexOfSelectedItem) ?? .lossless
                let webpFiles = try WebPService.convert(files: files, mode: mode)
                webpCount = webpFiles.count
            }

            tableView.reloadData()
            if shouldConvert {
                updateState(message: "已重命名 \(files.count) 张图片，并生成 \(webpCount) 张 WebP")
            } else {
                updateState(message: "已成功重命名 \(files.count) 张图片")
            }

            let success = NSAlert()
            success.messageText = "处理完成"
            success.informativeText = shouldConvert
                ? "已重命名 \(files.count) 张原图，并在 webp 文件夹生成 \(webpCount) 张 WebP。"
                : "共重命名 \(files.count) 张图片。"
            success.addButton(withTitle: "完成")
            success.alertStyle = .informational
            success.runModal()
        } catch {
            show(error: error)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        tableView.reloadData()
        updateRenameButton()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        files.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard files.indices.contains(row), let tableColumn else { return nil }

        let text: String
        if tableColumn.identifier.rawValue == "current" {
            text = files[row].lastPathComponent
        } else {
            let rawBaseName = baseNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let baseName = rawBaseName.isEmpty ? "名称" : rawBaseName
            text = RenameService.previewName(for: files[row], baseName: baseName, index: row)
        }

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        return label
    }

    private func updateState(message: String) {
        statusLabel.stringValue = message
        updateRenameButton()
    }

    private func updateRenameButton() {
        let hasName = !baseNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        renameButton.isEnabled = !files.isEmpty && hasName
    }

    private func show(error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法完成操作"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.alertStyle = .warning
        alert.runModal()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var viewController: RenameViewController?
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = RenameViewController()
        let window = NSWindow(contentViewController: controller)
        window.title = "图片批量编号重命名"
        window.setContentSize(NSSize(width: 720, height: 590))
        window.minSize = NSSize(width: 640, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.viewController = controller
        self.window = window

        if !pendingURLs.isEmpty {
            controller.load(urls: pendingURLs)
            pendingURLs = []
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let viewController {
            viewController.load(urls: urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

private func runSelfTest() throws {
    let fileManager = FileManager.default
    let testFolder = fileManager.temporaryDirectory
        .appendingPathComponent("bruce-image-renamer-test-\(UUID().uuidString)")

    try fileManager.createDirectory(at: testFolder, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: testFolder) }

    let originalNames = ["photo-10.png", "photo-2.webp", "photo-1.jpg"]
    for name in originalNames {
        try Data("test".utf8).write(to: testFolder.appendingPathComponent(name))
    }

    let sorted = try RenameService.sortedImageURLs(from: [testFolder])
    let renamed = try RenameService.rename(files: sorted, baseName: "产品图")
    let results = renamed.map(\.lastPathComponent)

    let expected = ["产品图-1.jpg", "产品图-2.webp", "产品图-3.png"]
    guard results == expected,
          renamed.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else {
        throw RenameError.operationFailed("自检失败：\(results)")
    }

    print("SELF_TEST_OK: \(results.joined(separator: ", "))")

    if WebPService.executableURL() != nil {
        let pngSource = testFolder.appendingPathComponent("webp测试.png")
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw WebPError.conversionFailed("无法生成测试图片")
        }
        bitmap.setColor(NSColor(deviceRed: 0.10, green: 0.35, blue: 0.85, alpha: 1), atX: 0, y: 0)
        bitmap.setColor(NSColor(deviceRed: 0.05, green: 0.55, blue: 0.50, alpha: 1), atX: 1, y: 0)
        bitmap.setColor(NSColor(deviceWhite: 1, alpha: 1), atX: 0, y: 1)
        bitmap.setColor(NSColor(deviceWhite: 0, alpha: 0), atX: 1, y: 1)

        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw WebPError.conversionFailed("无法编码测试 PNG")
        }
        try pngData.write(to: pngSource)
        try WebPService.preflight(files: [pngSource])
        let webpResults = try WebPService.convert(files: [pngSource], mode: .lossless)
        guard webpResults.count == 1,
              fileManager.fileExists(atPath: webpResults[0].path) else {
            throw WebPError.conversionFailed("自检没有生成 WebP 文件")
        }
        print("WEBP_TEST_OK: \(webpResults[0].lastPathComponent)")
    }
}

@main
struct ImageBatchRenamerApp {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            do {
                try runSelfTest()
                exit(EXIT_SUCCESS)
            } catch {
                fputs("SELF_TEST_FAILED: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
