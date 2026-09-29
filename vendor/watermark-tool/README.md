# AI Watermark Remover Tool / AI 水印移除小工具

A local web-based tool for inspecting and removing AI watermarks / provenance metadata from images and documents.

一个本地网页版小工具，用于检查并移除图片和文档中的 AI 水印 / 溯源元数据。

It is built on top of [watermarks-remover](https://github.com/guillaumemeyer/watermarks-remover) (MIT License) and wraps its Python scripts with a simple browser UI.

本项目基于 [watermarks-remover](https://github.com/guillaumemeyer/watermarks-remover)（MIT 协议），用简单的浏览器界面封装了它的 Python 脚本。

---

> # ⚠️ LEGAL DISCLAIMER / 法律免责声明
>
> ## 🚫 PROHIBITED USE / 禁止用途
>
> **严禁将本工具用于以下任何场景：** / **It is strictly prohibited to use this tool for any of the following:**
>
> - 侵犯他人版权，或未经授权移除他人作品中的水印、版权管理信息、来源标识 / Infringing others' copyright, or removing watermarks, copyright management information, or provenance identifiers from others' works without authorization
> - 违反《人工智能生成合成内容标识办法》或其他适用法律法规 / Violating the "Measures for the Labeling of AI-Generated Synthetic Content" or other applicable laws and regulations
> - 商业欺诈、虚假宣传、伪造“人工创作”身份、规避监管或检测 / Commercial fraud, false advertising, faking a "human-created" identity, evading regulation or detection
> - 任何可能损害他人合法权益或违反所在司法辖区法律的活动 / Any activity that may harm others' lawful rights or violate the laws of your jurisdiction
>
> ## ✅ LEGITIMATE USE / 推荐合法用途
>
> 本工具仅推荐用于：/ This tool is recommended only for:
>
> - 对自己生成或拥有合法权利的内容进行隐私清理研究 / Privacy-cleaning research on content you generated or lawfully own
> - 辅助内容合规性检查，例如确认自己作品的 AI 标识状态 / Assisting content compliance checks, such as confirming the AI labeling status of your own work
> - 在授权范围内进行学术研究、技术验证、安全测试 / Academic research, technical verification, and security testing within authorized scope
> - 用于个人生成内容的隐私保护与数据卫生管理 / Privacy protection and data hygiene management for personally generated content
>
> ## ⚖️ USER RESPONSIBILITY / 使用者责任
>
> 使用者必须自行确认其所在国家/地区的法律法规，并承担因使用本工具产生的一切法律责任。/ Users must independently confirm the laws and regulations of their jurisdiction and bear all legal responsibilities arising from the use of this tool.
>
> 开发者/维护者不对任何滥用、误用或非法使用行为承担责任。/ Developers and maintainers are not responsible for any abuse, misuse, or illegal use.
>
> 本工具仅提供技术能力，不构成法律意见。/ This tool only provides technical capability and does not constitute legal advice.

---

## Features / 功能

- Drag & drop or click to upload multiple files / 支持拖拽或点击上传，可多选
- Inspect first: show C2PA, AI metadata, invisible Unicode, SynthID info before cleaning / 支持“先检查数据”，展示 C2PA、AI 元数据、不可见 Unicode、SynthID 等信息
- Batch clean and download as ZIP / 支持批量清理，并可打包 ZIP 下载
- Supported formats / 支持格式：TXT, Markdown, HTML, PNG, JPEG, WebP, SVG, PDF, DOCX, ODT
- Local-only, no public upload / 纯本地运行，不上传到公网
- Advanced placeholders reserved: Layer B text rewriting, pixel-level image watermark removal / 预留高级功能：Layer B 文本重写、图片像素级水印移除

---

## How It Works / 实现原理

```
Browser
  │  upload files (multipart/form-data)
  ▼
server.py  (Python standard library HTTP server)
  │
  ├── POST /inspect
  │     └── vendor/watermarks-remover/service/scripts/inspect_file.py --json
  │           ├── Detect C2PA / EXIF / XMP / AI metadata
  │           ├── Detect invisible Unicode (Layer A)
  │           └── Detect optional SynthID / pixel clues
  │
  ├── POST /clean
  │     └── vendor/watermarks-remover/service/scripts/clean_file.py --json
  │           ├── Layer A: remove invisible Unicode / exotic spaces / bidi controls
  │           ├── File cleaners: strip C2PA / EXIF / XMP / document properties
  │           ├── Optional Layer B: rewrite text to weaken statistical watermarks
  │           └── Optional pixel removal: CtrlRegen / MarkDiffusion
  │
  └── Download cleaned files / ZIP
```

### Core Ideas / 核心思路

1. **Inspect first / 先检查**
   - The tool calls the upstream `inspect_file.py` and converts JSON output into a human-readable report.
   - 工具调用上游 `inspect_file.py`，把 JSON 输出转换成易读报告。

2. **Clean / 清理**
   - Text files: remove invisible Unicode carriers such as zero-width spaces, soft hyphens, bidi controls.
   - Images: drop C2PA chunks, AI-looking XMP, EXIF segments.
   - Documents: scrub document properties, custom XML, AI metadata.
   - 文本：清除零宽空格、软连字符、双向控制符等不可见字符。
   - 图片：移除 C2PA、AI 相关 XMP、EXIF 段。
   - 文档：清理文档属性、自定义 XML、AI 元数据。

3. **Advanced / 高级（预留）**
   - Layer B text rewriting requires an Ollama or OpenAI-compatible backend.
   - Pixel-level image removal requires CtrlRegen or MarkDiffusion backend (GPU recommended).
   - 未配置时自动跳过，不影响普通清理。
   - Layer B 文本重写需要 Ollama 或 OpenAI 兼容后端。
   - 图片像素级移除需要 CtrlRegen 或 MarkDiffusion 后端（建议 GPU）。
   - 未配置时自动跳过。

---

## Directory Structure / 目录结构

```
watermarks-remover-tool/
├── server.py                  # Local web server / 本地网页服务
├── setup.sh                   # Download upstream project / 下载上游项目
├── 启动工具.command             # macOS double-click launcher / macOS 双击启动
├── docs/
│   └── 高级功能接入说明.md       # Advanced integration guide / 高级功能接入文档
├── vendor/
│   └── watermarks-remover/    # Vendored upstream project (MIT) / 内置上游项目
├── LICENSE
└── README.md
```

---

## Quick Start / 快速开始

### macOS

```bash
cd "/path/to/watermarks-remover-tool"
python3 server.py --open-browser
```

Or double-click `启动工具.command`.

或者双击 `启动工具.command`。

### Linux / Windows

```bash
cd watermarks-remover-tool
bash setup.sh          # first time only / 第一次需要
python3 server.py      # http://127.0.0.1:8766
```

Open your browser at / 打开浏览器访问：

```
http://127.0.0.1:8766
```

---

## Usage / 使用方法

1. Upload one or more files / 上传一个或多个文件
2. Click “先检查数据” to inspect first / 点击“先检查数据”查看元数据
3. Click “基于这些文件继续清理” to clean / 点击“基于这些文件继续清理”
4. Or click “上传并清理” directly / 或直接点击“上传并清理”
5. Download individual files or all as ZIP / 单个下载或 ZIP 打包下载

---

## Advanced Options / 高级选项

The UI already includes reserved checkboxes:

- 文本重写（Layer B）/ Layer B Text Rewriting
- 图片像素级水印移除 / Pixel-level Image Watermark Removal

They are disabled by default and will be skipped if the backend is not configured.
See `docs/高级功能接入说明.md` for details.

界面已预留高级选项，未配置后端时自动跳过。
详细说明见 `docs/高级功能接入说明.md`。

---

## Compliance & Risk Monitoring / 合规与风险关注

> 持续关注国内外关于 AI 内容标识的法律法规和技术标准变化，它们会直接影响本工具的“风险等级”。

建议关注以下方向：

- 中国：《人工智能生成合成内容标识办法》及配套标准
- 欧盟：EU AI Act 及内容溯源/透明度要求
- 美国：NIST AI 相关标准、各州内容溯源立法趋势
- 国际标准：C2PA / Content Credentials、SynthID 等技术标准演进
- 平台政策：各内容平台对 AI 生成内容标识的识别与治理规则

如果相关法规或标准发生变化，请及时评估本工具是否仍可合法使用，并根据需要调整功能或停止使用。

---

## Credits / 致谢

This project references and vendors [watermarks-remover](https://github.com/guillaumemeyer/watermarks-remover) by Guillaume Meyer, licensed under MIT.

本项目参考并内置了 [watermarks-remover](https://github.com/guillaumemeyer/watermarks-remover)（MIT 协议）。

Vendored license: `vendor/watermarks-remover/LICENSE`

---

## License / 协议

MIT License. See [LICENSE](LICENSE).

本项目使用 MIT 协议，详见 [LICENSE](LICENSE)。
