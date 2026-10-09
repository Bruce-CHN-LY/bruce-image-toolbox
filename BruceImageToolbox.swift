import AppKit
import Darwin
import Foundation

private enum ToolboxPaths {
    static let renamerApp = "EmbeddedApps/ImageBatchRenamer.app"
    static let heicApp = "EmbeddedApps/HEICBatchConverter.app"
    static let copyrightApp = "EmbeddedApps/CopyrightMetadata.app"
    static let compressorScript = "Scripts/WordPressImageCompressor.command"
    static let watermarkTool = "WatermarkTool"

    static func resource(_ relativePath: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent(relativePath)
    }
}

private enum DependencyLocator {
    private static let candidates: [String: [String]] = [
        "cwebp": ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp"],
        "magick": ["/opt/homebrew/bin/magick", "/usr/local/bin/magick"],
        "pngquant": ["/opt/homebrew/bin/pngquant", "/usr/local/bin/pngquant"],
        "python3": [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/3.10/bin/python3",
            "/usr/bin/python3"
        ]
    ]

    static func executable(named name: String) -> URL? {
        let matches = candidates[name]?
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }

        if name == "python3" {
            return matches?.first { supportedPythonVersion(at: $0) != nil }
        }
        return matches?.first
    }

    private static func supportedPythonVersion(at executable: URL) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = [
            "-c",
            "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let text = String(
                  data: output.fileHandleForReading.readDataToEndOfFile(),
                  encoding: .utf8
              )?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }

        let components = text.split(separator: ".").compactMap { Int($0) }
        guard components.count >= 2,
              components[0] > 3 || (components[0] == 3 && components[1] >= 10) else {
            return nil
        }
        return text
    }

    static func statusSummary() -> String {
        let names = ["cwebp", "magick", "pngquant", "python3"]
        let ready = names.filter { executable(named: $0) != nil }
        return ready.count == names.count
            ? "运行环境已就绪：WebP、压缩与 Python 3.10+ 均可用"
            : "部分依赖未安装或版本过低：\(names.filter { executable(named: $0) == nil }.joined(separator: "、"))"
    }
}

private final class ToolCardView: NSBox {
    private let titleLabel = NSTextField(labelWithString: "")
    private let descriptionLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton: NSButton

    init(
        title: String,
        description: String,
        symbol: String,
        buttonTitle: String,
        target: AnyObject,
        action: Selector
    ) {
        actionButton = NSButton(title: buttonTitle, target: target, action: action)
        super.init(frame: .zero)
        boxType = .custom
        borderWidth = 1
        cornerRadius = 16
        contentViewMargins = NSSize(width: 20, height: 18)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.contentTintColor = NSColor.systemGreen
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 27, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 34),
            icon.heightAnchor.constraint(equalToConstant: 34)
        ])

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)

        descriptionLabel.stringValue = description
        descriptionLabel.font = NSFont.systemFont(ofSize: 13)
        descriptionLabel.maximumNumberOfLines = 3

        let textStack = NSStackView(views: [titleLabel, descriptionLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 5

        let topStack = NSStackView(views: [icon, textStack])
        topStack.orientation = .horizontal
        topStack.alignment = .top
        topStack.spacing = 12

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .large
        actionButton.keyEquivalent = ""

        let stack = NSStackView(views: [topStack, actionButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        guard let contentView else { return }
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 156)
        ])

        updateAppearanceColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearanceColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAppearanceColors()
    }

    private func updateAppearanceColors() {
        // NSBox 会缓存设置时已解析的颜色，外观切换后需要重新解析语义颜色。
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        fillColor = isDark
            ? NSColor(calibratedWhite: 0.16, alpha: 0.96)
            : NSColor(calibratedWhite: 0.98, alpha: 0.96)
        borderColor = isDark
            ? NSColor(calibratedWhite: 0.38, alpha: 0.65)
            : NSColor(calibratedWhite: 0.72, alpha: 0.65)
        titleLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.96, alpha: 1)
            : NSColor(calibratedWhite: 0.10, alpha: 1)
        descriptionLabel.textColor = isDark
            ? NSColor(calibratedWhite: 0.72, alpha: 1)
            : NSColor(calibratedWhite: 0.38, alpha: 1)
        actionButton.contentTintColor = isDark ? .white : .controlTextColor
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var watermarkProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if watermarkProcess?.isRunning == true {
            watermarkProcess?.terminate()
        }
    }

    private func createMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bruce 图片工具箱"
        window.minSize = NSSize(width: 820, height: 650)
        window.center()

        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .active
        window.contentView = background

        let headerIcon = NSImageView()
        headerIcon.image = NSImage(systemSymbolName: "photo.stack", accessibilityDescription: "图片工具箱")
        headerIcon.contentTintColor = NSColor.systemGreen
        headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .semibold)
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerIcon.widthAnchor.constraint(equalToConstant: 44),
            headerIcon.heightAnchor.constraint(equalToConstant: 44)
        ])

        let titleLabel = NSTextField(labelWithString: "Bruce 图片工具箱")
        titleLabel.font = NSFont.systemFont(ofSize: 27, weight: .bold)

        let subtitleLabel = NSTextField(labelWithString: "批量处理产品图片，所有文件均在本机完成")
        subtitleLabel.font = NSFont.systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor

        let titleStack = NSStackView(views: [titleLabel, subtitleLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        let header = NSStackView(views: [headerIcon, titleStack])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let statusLabel = NSTextField(labelWithString: DependencyLocator.statusSummary())
        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = DependencyLocator.statusSummary().contains("已就绪")
            ? .systemGreen
            : .systemOrange

        let renamer = ToolCardView(
            title: "批量重命名与 WebP",
            description: "拖入图片，按“名称-1”到“名称-n”统一编号；可同时生成无损或质量 85 的 WebP。",
            symbol: "textformat.123",
            buttonTitle: "打开重命名工具",
            target: self,
            action: #selector(openRenamer)
        )

        let compressor = ToolCardView(
            title: "WordPress 图片压缩",
            description: "批量缩放并压缩 PNG、HEIC 和 HEIF，原图不改动，结果保存到 compressed 文件夹。",
            symbol: "arrow.down.right.and.arrow.up.left",
            buttonTitle: "开始压缩图片",
            target: self,
            action: #selector(openCompressor)
        )

        let heic = ToolCardView(
            title: "HEIC 批量转换",
            description: "把 HEIC/HEIF 批量转换成 JPG 或 PNG，可设置质量与输出位置。",
            symbol: "arrow.triangle.2.circlepath",
            buttonTitle: "打开转换工具",
            target: self,
            action: #selector(openHEICConverter)
        )

        let copyright = ToolCardView(
            title: "写入图片版权信息",
            description: "批量写入作者与版权元数据，不在画面上显示文字，并支持安全替换或输出副本。",
            symbol: "c.circle",
            buttonTitle: "打开版权工具",
            target: self,
            action: #selector(openCopyrightTool)
        )

        let watermark = ToolCardView(
            title: "水印与溯源元数据清理",
            description: "启动本地网页检查并清理自己有权处理文件中的 AI 标识、EXIF、XMP 与文档元数据。",
            symbol: "wand.and.stars.inverse",
            buttonTitle: "启动本地清理页面",
            target: self,
            action: #selector(openWatermarkTool)
        )

        let help = ToolCardView(
            title: "使用原则",
            description: "工具不会上传文件。处理前请确认拥有相应内容的使用权；原图重要时请先保留备份。",
            symbol: "checkmark.shield",
            buttonTitle: "查看工具说明",
            target: self,
            action: #selector(showHelp)
        )

        let grid = NSGridView(views: [
            [renamer, compressor],
            [heic, copyright],
            [watermark, help]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.column(at: 0).xPlacement = .fill
        grid.column(at: 1).xPlacement = .fill

        let rootStack = NSStackView(views: [header, statusLabel, grid])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 18
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 28),
            rootStack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -28),
            rootStack.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor, constant: -26),
            grid.leadingAnchor.constraint(equalTo: rootStack.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: rootStack.trailingAnchor)
        ])

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openRenamer() {
        openEmbeddedApp(relativePath: ToolboxPaths.renamerApp, displayName: "批量重命名工具")
    }

    @objc private func openHEICConverter() {
        openEmbeddedApp(relativePath: ToolboxPaths.heicApp, displayName: "HEIC 转换工具")
    }

    @objc private func openCopyrightTool() {
        openEmbeddedApp(relativePath: ToolboxPaths.copyrightApp, displayName: "版权信息工具")
    }

    @objc private func openCompressor() {
        guard let script = ToolboxPaths.resource(ToolboxPaths.compressorScript),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            showError("没有找到图片压缩脚本。请重新安装 Bruce 图片工具箱。")
            return
        }

        guard DependencyLocator.executable(named: "magick") != nil,
              DependencyLocator.executable(named: "pngquant") != nil else {
            showError("图片压缩需要 ImageMagick 和 pngquant。请在终端运行：\nbrew install imagemagick pngquant")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", script.path]

        do {
            try process.run()
        } catch {
            showError("无法启动图片压缩工具：\(error.localizedDescription)")
        }
    }

    @objc private func openWatermarkTool() {
        if isWatermarkServerAvailable() {
            openWatermarkPage()
            return
        }

        guard let python = DependencyLocator.executable(named: "python3") else {
            showError("没有找到 Python 3.10 或更高版本，无法启动本地清理页面。请在终端运行：\nbrew install python")
            return
        }

        do {
            let installedTool = try installWatermarkToolIfNeeded()
            let server = installedTool.appendingPathComponent("server.py")

            let process = Process()
            process.executableURL = python
            process.arguments = [server.path, "--host", "127.0.0.1", "--port", "8766"]
            process.currentDirectoryURL = installedTool
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            watermarkProcess = process

            // 本地服务启动后再打开浏览器，避免首次访问早于端口监听。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                self?.openWatermarkPage()
            }
        } catch {
            showError("无法启动本地清理工具：\(error.localizedDescription)")
        }
    }

    @objc private func showHelp() {
        let message = """
        1. 批量重命名与 WebP：统一编号并生成网页图片。
        2. WordPress 图片压缩：原图保留，结果写入 compressed。
        3. HEIC 转换：输出 JPG 或 PNG。
        4. 版权信息：写入图片元数据，不改变画面。
        5. 水印与溯源元数据清理：仅处理自己拥有或获授权的文件。
        """
        let alert = NSAlert()
        alert.messageText = "Bruce 图片工具箱"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func openEmbeddedApp(relativePath: String, displayName: String) {
        guard let appURL = ToolboxPaths.resource(relativePath),
              FileManager.default.fileExists(atPath: appURL.path) else {
            showError("没有找到\(displayName)。请重新安装 Bruce 图片工具箱。")
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { [weak self] _, error in
            if let error {
                DispatchQueue.main.async {
                    self?.showError("无法启动\(displayName)：\(error.localizedDescription)")
                }
            }
        }
    }

    private func installWatermarkToolIfNeeded() throws -> URL {
        guard let bundledTool = ToolboxPaths.resource(ToolboxPaths.watermarkTool) else {
            throw NSError(
                domain: "com.bruce.image-toolbox",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "应用资源中缺少水印清理工具。"]
            )
        }

        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport.appendingPathComponent("Bruce Image Toolbox", isDirectory: true)
        let destination = root.appendingPathComponent("WatermarkTool-v1", isDirectory: true)

        if !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundledTool, to: destination)
        }

        return destination
    }

    private func isWatermarkServerAvailable() -> Bool {
        if watermarkProcess?.isRunning == true {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        process.arguments = ["-z", "-G", "1", "127.0.0.1", "8766"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func openWatermarkPage() {
        guard let url = URL(string: "http://127.0.0.1:8766") else { return }
        NSWorkspace.shared.open(url)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "无法完成操作"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}

private enum SelfCheck {
    private static let requiredResources: [(String, Bool)] = [
        (ToolboxPaths.renamerApp, false),
        (ToolboxPaths.heicApp, false),
        (ToolboxPaths.copyrightApp, false),
        (ToolboxPaths.compressorScript, true),
        ("\(ToolboxPaths.watermarkTool)/server.py", false),
        ("\(ToolboxPaths.watermarkTool)/vendor/watermarks-remover/service/scripts/clean_file.py", false)
    ]

    static func run() -> Int32 {
        var failed = false
        let fileManager = FileManager.default

        for (path, mustBeExecutable) in requiredResources {
            guard let url = ToolboxPaths.resource(path) else {
                print("FAIL resource URL: \(path)")
                failed = true
                continue
            }

            let exists = fileManager.fileExists(atPath: url.path)
            let executable = !mustBeExecutable || fileManager.isExecutableFile(atPath: url.path)
            print("\(exists && executable ? "OK" : "FAIL") resource: \(path)")
            failed = failed || !exists || !executable
        }

        for dependency in ["cwebp", "magick", "pngquant", "python3"] {
            let executable = DependencyLocator.executable(named: dependency)
            print("\(executable == nil ? "FAIL" : "OK") dependency: \(dependency)\(executable.map { " -> \($0.path)" } ?? "")")
            failed = failed || executable == nil
        }

        print(failed ? "SELF_CHECK_FAILED" : "SELF_CHECK_OK")
        return failed ? 1 : 0
    }
}

@main
private struct BruceImageToolboxApp {
    static func main() {
        if CommandLine.arguments.contains("--self-check") {
            exit(SelfCheck.run())
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
