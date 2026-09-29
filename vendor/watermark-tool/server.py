# -*- coding: utf-8 -*-
"""
watermarks-remover 小工具
一个本地网页版上传清理工具：图片 / 文档上传后，调用上游项目清理并下载。

依赖：Python 3.10+，仅标准库。
默认寻找 vendor/watermarks-remover，也可用环境变量 WATERMARKS_REMOVER_REPO 指定仓库路径。
"""

import html
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import zipfile
from email.parser import BytesParser
from email import policy
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
REPO_DIR = Path(os.environ.get("WATERMARKS_REMOVER_REPO", BASE_DIR / "vendor" / "watermarks-remover")).resolve()
SCRIPTS_DIR = REPO_DIR / "service" / "scripts"
PROCESSED_DIR = BASE_DIR / "processed"
PROCESSED_DIR.mkdir(exist_ok=True)

MAX_UPLOAD_SIZE = 50 * 1024 * 1024  # 50 MB
CLEANUP_AGE_SECONDS = 2 * 3600  # 清理 2 小时前的临时文件

# token -> info
JOBS = {}
JOBS_LOCK = threading.Lock()

PAGE_TEMPLATE = """<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI 水印移除小工具</title>
<style>
  :root {{
    --bg: #f5f7fb;
    --card: #ffffff;
    --primary: #2563eb;
    --primary-dark: #1d4ed8;
    --text: #1f2937;
    --muted: #6b7280;
    --border: #e5e7eb;
    --success: #16a34a;
    --warning: #d97706;
    --error: #dc2626;
    --radius: 16px;
  }}
  * {{ box-sizing: border-box; }}
  body {{
    margin: 0;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif;
    background: var(--bg);
    color: var(--text);
    line-height: 1.6;
  }}
  .container {{ max-width: 860px; margin: 0 auto; padding: 32px 16px; }}
  .card {{
    background: var(--card);
    border-radius: var(--radius);
    box-shadow: 0 4px 20px rgba(0,0,0,.06);
    padding: 28px;
    margin-bottom: 20px;
  }}
  h1 {{ margin-top: 0; font-size: 1.5rem; }}
  .subtitle {{ color: var(--muted); margin-top: -8px; }}
  .drop-zone {{
    border: 2px dashed #cbd5e1;
    border-radius: 12px;
    padding: 40px 20px;
    text-align: center;
    cursor: pointer;
    transition: border-color .15s, background .15s;
    background: #fafbfc;
  }}
  .drop-zone:hover, .drop-zone.drag {{ border-color: var(--primary); background: #eff6ff; }}
  .drop-zone input[type=file] {{ display: none; }}
  .file-name {{ margin-top: 10px; font-weight: 600; word-break: break-all; }}
  .btn {{
    display: inline-block;
    background: var(--primary);
    color: #fff;
    border: none;
    border-radius: 10px;
    padding: 12px 24px;
    font-size: 1rem;
    font-weight: 600;
    cursor: pointer;
    margin-top: 16px;
    transition: background .15s;
  }}
  .btn:hover {{ background: var(--primary-dark); }}
  .btn:disabled {{ background: #9ca3af; cursor: not-allowed; }}
  .btn.secondary {{ background: #16a34a; }}
  .btn.secondary:hover {{ background: #15803d; }}
  .status {{ margin-top: 16px; font-weight: 600; color: var(--muted); }}
  .report {{ background: #f8fafc; border: 1px solid var(--border); border-radius: 10px; padding: 16px; margin-top: 16px; overflow-x: auto; }}
  .report pre {{ margin: 0; white-space: pre-wrap; word-break: break-word; font-size: .85rem; }}
  .badge {{ display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: .8rem; margin-left: 8px; }}
  .badge.ok {{ background: #dcfce7; color: var(--success); }}
  .badge.warn {{ background: #fef3c7; color: var(--warning); }}
  .badge.error {{ background: #fee2e2; color: var(--error); }}
  .tip {{ color: var(--muted); font-size: .9rem; margin-top: 16px; }}
  .download-panel {{ text-align: center; }}
  .actions {{ display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; }}
  a.btn {{ text-decoration: none; }}
</style>
</head>
<body>
<div class="container">
  {content}
</div>
<script>
  const dropZone = document.getElementById('drop-zone');
  const fileInput = document.getElementById('file-input');
  const fileName = document.getElementById('file-name');
  if (dropZone && fileInput) {{
    dropZone.addEventListener('click', () => fileInput.click());
    dropZone.addEventListener('dragover', e => {{ e.preventDefault(); dropZone.classList.add('drag'); }});
    dropZone.addEventListener('dragleave', () => dropZone.classList.remove('drag'));
    dropZone.addEventListener('drop', e => {{
      e.preventDefault();
      dropZone.classList.remove('drag');
      if (e.dataTransfer.files.length) {{
        fileInput.files = e.dataTransfer.files;
        updateFileNames(fileInput.files);
      }}
    }});
    fileInput.addEventListener('change', () => {{
      updateFileNames(fileInput.files);
    }});
    function updateFileNames(files) {{
      if (!files || !files.length) {{
        fileName.textContent = '';
        return;
      }}
      const names = Array.from(files).map(f => f.name);
      fileName.textContent = '已选择 ' + files.length + ' 个文件：' + names.join('、');
    }}
  }}
</script>
</body>
</html>
"""

INDEX_CONTENT = """
<div class="card">
  <h1>🛁 AI 水印移除小工具</h1>
  <p class="subtitle">基于 <a href="https://github.com/guillaumemeyer/watermarks-remover" target="_blank">watermarks-remover</a> 的本地网页版</p>
  <form id="upload-form" action="/clean" method="post" enctype="multipart/form-data">
    <div id="drop-zone" class="drop-zone">
      <p style="margin:0">📁 点击选择或拖拽文件到这里</p>
      <p style="margin:8px 0 0; font-size:.85rem; color:var(--muted)">支持多选批量上传：文本、Markdown、HTML、PNG、JPEG、WebP、PDF、DOCX、ODT、SVG 等</p>
      <input type="file" id="file-input" name="file" multiple required>
      <div id="file-name" class="file-name"></div>
    </div>
    <div style="margin-top:16px;padding:16px;background:#f8fafc;border:1px solid var(--border);border-radius:12px">
      <strong>高级选项（预留）</strong>
      <p style="margin:6px 0;font-size:.85rem;color:var(--muted)">
        当前普通清理默认开启；高级功能未配置时会自动跳过，不影响正常使用。
      </p>
      <label style="display:block;margin-top:8px;cursor:pointer">
        <input type="checkbox" name="rewrite" value="1"> 文本重写（Layer B）— 用于统计型文本水印，需要配置 Ollama / OpenAI 兼容后端
      </label>
      <label style="display:block;margin-top:6px;cursor:pointer">
        <input type="checkbox" name="pixel" value="1"> 图片像素级水印移除 — 需要配置 CtrlRegen 或 MarkDiffusion 后端（建议 GPU）
      </label>
    </div>
    <div style="text-align:center;display:flex;gap:12px;justify-content:center;flex-wrap:wrap">
      <button class="btn" id="inspect-btn" type="submit" formaction="/inspect" style="background:#6b7280">🔍 先检查数据</button>
      <button class="btn" id="submit-btn" type="submit" formaction="/clean">上传并清理</button>
    </div>
    <div id="status" class="status"></div>
  </form>
  <p class="tip">⚠️ 请只上传你拥有或有权处理的内容。工具尽力清理 AI 水印与元数据，但不保证能通过所有厂商官方检测。</p>
</div>
"""

RESULT_CONTENT = """
<div class="card">
  <h1>✅ 清理完成</h1>
  <p><strong>原始文件：</strong>{orig_name}</p>
  <p><strong>清理状态：</strong>{status_html}</p>
  <div class="download-panel">
    <div class="actions">
      <a class="btn secondary" href="/download/{token}">⬇️ 下载清理后的文件</a>
      <a class="btn" href="/" style="background:#6b7280;color:#fff">↩️ 继续清理下一个</a>
    </div>
  </div>
  <div class="report">
    <h3 style="margin-top:0">清理报告</h3>
    <pre>{report_html}</pre>
  </div>
  <p class="tip">提示：如果报告为空或没有找到水印，说明文件可能没有检测到可移除的常见 AI 水印/元数据。</p>
</div>
"""

BATCH_RESULT_CONTENT = """
<div class="card">
  <h1>✅ 批量清理完成</h1>
  <p><strong>成功：</strong>{success_count} 个，<strong>失败：</strong>{fail_count} 个</p>
  <div class="download-panel">
    <div class="actions">
      <a class="btn secondary" href="/download-all/{token}">⬇️ 下载全部（ZIP 打包）</a>
      <a class="btn" href="/" style="background:#6b7280;color:#fff">↩️ 继续上传</a>
    </div>
  </div>
  <div class="report">
    <h3 style="margin-top:0">逐文件报告</h3>
    {files_html}
  </div>
  <p class="tip">提示：如果某个文件报告为空或没有找到水印，说明它可能没有检测到可移除的常见 AI 水印/元数据。</p>
</div>
"""

INSPECT_RESULT_CONTENT = """
<div class="card">
  <h1>🔍 检查完成</h1>
  <p>下面是上传文件的检查数据，可据此判断是否已经处理过。</p>
  <div class="actions">
    <form action="/clean/{token}" method="post" style="display:inline">
      <button class="btn secondary" type="submit">⬇️ 基于这些文件继续清理</button>
    </form>
    <a class="btn" href="/" style="background:#6b7280;color:#fff">↩️ 返回重新选择</a>
  </div>
  <div class="report">
    <h3 style="margin-top:0">逐文件检查结果</h3>
    {files_html}
  </div>
  <p class="tip">提示：如果显示“C2PA：否 / AI 元数据：否 / 可疑字符：0”，通常说明这份文件看起来已经比较干净。</p>
</div>
"""

ERROR_CONTENT = """
<div class="card">
  <h1>❌ 处理失败</h1>
  <p>{message}</p>
  <div class="report"><pre>{detail}</pre></div>
  <a class="btn" href="/" style="background:#6b7280;color:#fff">↩️ 返回重试</a>
</div>
"""


def repo_ok():
    return SCRIPTS_DIR.joinpath("clean_file.py").is_file()


def sanitize_filename(name):
    name = os.path.basename(name or "upload.bin")
    name = re.sub(r"[^A-Za-z0-9._\-\u4e00-\u9fff ()（）]+", "_", name)
    return name[:200] or "upload.bin"


TEXT_EXTENSIONS = {".txt", ".md", ".markdown", ".html", ".htm", ".csv", ".json", ".xml", ".yaml", ".yml", ".rst", ".log", ".tex", ".org"}
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".webp", ".bmp", ".gif", ".tif", ".tiff"}


def is_text_file(name):
    return Path(name).suffix.lower() in TEXT_EXTENSIONS


def is_image_file(name):
    return Path(name).suffix.lower() in IMAGE_EXTENSIONS


def run_script(args, timeout=120):
    """Run a repo script, return (returncode, stdout, stderr)."""
    cmd = [sys.executable, str(args[0])] + [str(a) for a in args[1:]]
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return proc.returncode, proc.stdout, proc.stderr


def parse_report_json(raw):
    """Try to extract a JSON object from stdout, tolerate leading text/warnings."""
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:
        pass
    # Sometimes there may be warnings before JSON; try to find the first { ... }
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        try:
            return json.loads(raw[start:end + 1])
        except Exception:
            return None
    return None


def format_report(raw_json, stderr=""):
    """Build a human-readable multiline report."""
    lines = []
    if stderr and stderr.strip():
        lines.append("[stderr]")
        lines.append(stderr.strip())
        lines.append("")
    data = parse_report_json(raw_json)
    if data is None:
        lines.append(raw_json.strip() if raw_json.strip() else "(无输出)")
        return "\n".join(lines)
    if data.get("kind") == "container":
        fmt = data.get("format", "unknown")
        lines.append(f"文件类型：{fmt}")
        actions = data.get("actions") or []
        if actions:
            lines.append("清理动作：")
            for act in actions:
                lines.append(f"  - {act}")
        findings = data.get("post_findings") or []
        if findings:
            lines.append("清理后残留：")
            for f in findings:
                lines.append(f"  - {f}")
        if data.get("still_has_c2pa") or data.get("still_has_ai_metadata"):
            lines.append("⚠️ 仍检测到 C2PA / AI 元数据残留")
        if "bytes_in" in data and "bytes_out" in data:
            lines.append(f"大小：{data['bytes_in']} -> {data['bytes_out']} 字节")
    elif data.get("kind") in ("text", "image"):
        # fallback: dump whole JSON pretty
        lines.append(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        lines.append(json.dumps(data, ensure_ascii=False, indent=2))
    return "\n".join(lines)


def format_inspect_pretty(raw_json, stderr=""):
    """把 inspect_file.py 的 JSON 转成更容易看懂的检查报告。"""
    lines = []
    if stderr and stderr.strip():
        lines.append("[stderr]")
        lines.append(stderr.strip())
        lines.append("")
    data = parse_report_json(raw_json)
    if data is None:
        lines.append(raw_json.strip() if raw_json.strip() else "(无输出)")
        return "\n".join(lines)

    lines.append(f"文件类型：{data.get('format') or data.get('kind') or '未知'}")
    if data.get("has_c2pa") is not None:
        lines.append(f"C2PA 内容凭证：{'是' if data['has_c2pa'] else '否'}")
    if data.get("has_ai_metadata") is not None:
        lines.append(f"AI 元数据：{'是' if data['has_ai_metadata'] else '否'}")

    suspicious_total = data.get("suspicious_total", 0)
    if suspicious_total:
        lines.append(f"可疑不可见字符数量：{suspicious_total}")

    findings = data.get("findings") or []
    hits = data.get("layer_a_hits") or []
    if findings:
        lines.append("发现：")
        for f in findings:
            lines.append(f"  - {f}")
    if hits:
        lines.append("Layer A 命中：")
        for h in hits:
            lines.append(f"  - {h.get('codepoint')} {h.get('label')} x{h.get('count')}")

    synthid = data.get("synthid")
    if synthid is not None:
        lines.append(f"SynthID 检测：{synthid}")

    tools = data.get("tools") or {}
    if tools:
        available = [k for k, v in tools.items() if isinstance(v, dict) and v.get("available")]
        lines.append(f"可用检测工具：{', '.join(available) if available else '无'}")

    notes = data.get("notes") or []
    if notes:
        lines.append("备注：")
        for n in notes:
            lines.append(f"  - {n}")

    if len(lines) == 1 and not lines[0].startswith("文件类型"):
        lines.append(json.dumps(data, ensure_ascii=False, indent=2))
    return "\n".join(lines)


def build_page(content):
    return PAGE_TEMPLATE.format(content=content)


class Handler(BaseHTTPRequestHandler):
    server_version = "WatermarksRemoverTool/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _send_html(self, body, status=200):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_text(self, text, status=200):
        data = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/":
            if not repo_ok():
                content = ERROR_CONTENT.format(
                    message="没有找到 watermarks-remover 项目代码。",
                    detail="请先运行 setup.sh 下载依赖，或设置 WATERMARKS_REMOVER_REPO 指向项目路径。"
                )
                self._send_html(build_page(content))
                return
            self._send_html(build_page(INDEX_CONTENT))
            return
        if path.startswith("/download-all/"):
            token = path[len("/download-all/"):]
            self.handle_download_all(token)
            return
        if path.startswith("/download/"):
            rest = path[len("/download/"):]
            parts = rest.split("/")
            token = parts[0]
            index = None
            if len(parts) > 1:
                try:
                    index = int(parts[1])
                except ValueError:
                    index = None
            self.handle_download(token, index)
            return
        self._send_text("Not Found", 404)

    def do_POST(self):
        if self.path == "/clean":
            self.handle_clean()
            return
        if self.path == "/inspect":
            self.handle_inspect()
            return
        if self.path.startswith("/clean/"):
            token = self.path[len("/clean/"):]
            self.handle_clean_token(token)
            return
        self._send_text("Not Found", 404)

    def _parse_upload_body(self):
        """Read and parse multipart body. Returns (uploads, options)."""
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            raise ValueError("请求为空")
        if length > MAX_UPLOAD_SIZE:
            raise ValueError(f"文件过大，最大支持 {MAX_UPLOAD_SIZE // (1024*1024)} MB")
        body = self.rfile.read(length)
        uploads, options = self._parse_form(body)
        if not uploads:
            raise ValueError("没有收到文件字段，请重新选择文件")
        return uploads, options

    def handle_clean(self):
        if not repo_ok():
            content = ERROR_CONTENT.format(
                message="没有找到 watermarks-remover 项目代码。",
                detail="请先运行 setup.sh 下载依赖，或设置 WATERMARKS_REMOVER_REPO 指向项目路径。"
            )
            self._send_html(build_page(content), 500)
            return
        try:
            uploads, options = self._parse_upload_body()
        except Exception as e:
            content = ERROR_CONTENT.format(
                message="上传解析失败：" + html.escape(str(e)),
                detail="请返回重试。"
            )
            self._send_html(build_page(content), 400)
            return
        self._process_uploads(uploads, options)

    def handle_inspect(self):
        if not repo_ok():
            content = ERROR_CONTENT.format(
                message="没有找到 watermarks-remover 项目代码。",
                detail="请先运行 setup.sh 下载依赖，或设置 WATERMARKS_REMOVER_REPO 指向项目路径。"
            )
            self._send_html(build_page(content), 500)
            return
        try:
            uploads, options = self._parse_upload_body()
        except Exception as e:
            content = ERROR_CONTENT.format(
                message="上传解析失败：" + html.escape(str(e)),
                detail="请返回重试。"
            )
            self._send_html(build_page(content), 400)
            return

        token = uuid.uuid4().hex
        workdir = PROCESSED_DIR / token
        workdir.mkdir(exist_ok=True)
        with JOBS_LOCK:
            JOBS[token] = {
                "uploads": uploads,
                "options": options,
                "created": time.time(),
            }

        files_html = []
        for idx, (filename, filedata) in enumerate(uploads):
            safe_name = sanitize_filename(filename)
            upload_path = workdir / ("upload_" + str(idx) + "_" + safe_name)
            upload_path.write_bytes(filedata)
            try:
                rc_i, out_i, err_i = run_script([SCRIPTS_DIR / "inspect_file.py", upload_path, "--json"])
            except Exception as e:
                rc_i, out_i, err_i = 1, "", f"inspect 执行失败: {e}"
            report = format_inspect_pretty(out_i, err_i)
            files_html.append(
                f'<div style="border-top:1px solid var(--border);padding:12px 0">'
                f'<h4 style="margin:0 0 4px">{idx + 1}. {html.escape(safe_name)}</h4>'
                f'<pre>{html.escape(report)}</pre>'
                f'</div>'
            )

        content = INSPECT_RESULT_CONTENT.format(
            token=token,
            files_html="".join(files_html),
        )
        self._send_html(build_page(content))

    def handle_clean_token(self, token):
        with JOBS_LOCK:
            info = JOBS.get(token)
        if not info or "uploads" not in info:
            content = ERROR_CONTENT.format(
                message="检查会话不存在或已过期，请重新上传。",
                detail=""
            )
            self._send_html(build_page(content), 404)
            return
        uploads = info["uploads"]
        options = info.get("options", {})
        self._process_uploads(uploads, options)

    def _process_uploads(self, uploads, options):
        token = uuid.uuid4().hex
        workdir = PROCESSED_DIR / token
        workdir.mkdir(exist_ok=True)
        results = []
        success_count = 0
        fail_count = 0

        for idx, (filename, filedata) in enumerate(uploads):
            safe_name = sanitize_filename(filename)
            if not filedata:
                results.append({
                    "name": safe_name,
                    "ok": False,
                    "report": "文件内容为空",
                    "download_index": None,
                })
                fail_count += 1
                continue

            upload_path = workdir / ("upload_" + str(idx) + "_" + safe_name)
            cleaned_path = workdir / ("cleaned_" + str(idx) + "_" + safe_name)
            upload_path.write_bytes(filedata)

            # 1) 检查
            try:
                rc_i, out_i, err_i = run_script([SCRIPTS_DIR / "inspect_file.py", upload_path, "--json"])
            except Exception as e:
                rc_i, out_i, err_i = 1, "", f"inspect 执行失败: {e}"
            # 2) 清理
            try:
                rc_c, out_c, err_c = run_script([SCRIPTS_DIR / "clean_file.py", upload_path, "-o", cleaned_path, "--json"])
            except Exception as e:
                rc_c, out_c, err_c = 1, "", f"clean 执行失败: {e}"

            if not cleaned_path.is_file():
                results.append({
                    "name": safe_name,
                    "ok": False,
                    "report": (err_c + "\n" + out_c).strip() or "未知错误",
                    "download_index": None,
                })
                fail_count += 1
                continue

            inspect_report = format_report(out_i, err_i)
            clean_report = format_report(out_c, err_c)
            combined = f"【检查报告】\n{inspect_report}\n\n【清理报告】\n{clean_report}"
            advanced_notes = []

            # 高级选项：Layer B 文本重写（预留）
            if options.get("rewrite") and is_text_file(safe_name):
                if os.environ.get("WATERMARKS_REWRITE_BACKEND"):
                    rewritten_path = workdir / ("rewritten_" + str(idx) + "_" + safe_name)
                    try:
                        rc_r, out_r, err_r = run_script(
                            [SCRIPTS_DIR / "rewrite_text.py", cleaned_path, "-o", rewritten_path],
                            timeout=300,
                        )
                        if rewritten_path.is_file():
                            advanced_notes.append("Layer B 文本重写：已执行")
                            cleaned_path = rewritten_path
                            combined += "\n\n【Layer B 文本重写】\n" + format_report(out_r, err_r)
                        else:
                            advanced_notes.append("Layer B 文本重写：执行失败，保留普通清理结果")
                            combined += "\n\n【Layer B 文本重写】失败：\n" + (err_r + "\n" + out_r).strip()
                    except Exception as e:
                        advanced_notes.append("Layer B 文本重写：异常，已跳过")
                else:
                    advanced_notes.append("Layer B 文本重写：未配置 WATERMARKS_REWRITE_BACKEND，已跳过")
            elif options.get("rewrite"):
                advanced_notes.append("Layer B 文本重写：仅适用于文本文件，已跳过")

            # 高级选项：图片像素级水印移除（预留）
            if options.get("pixel") and is_image_file(safe_name):
                backend = None
                if os.environ.get("NOAI_WATERMARK_DIR"):
                    backend = "ctrlregen"
                elif os.environ.get("MARKDIFFUSION_DIR"):
                    backend = "diffusion"
                if backend:
                    pixel_path = workdir / ("pixel_" + str(idx) + "_" + safe_name)
                    try:
                        rc_p, out_p, err_p = run_script(
                            [SCRIPTS_DIR / "clean_image.py", cleaned_path, "-o", pixel_path, "--remove-pixel", backend],
                            timeout=600,
                        )
                        if pixel_path.is_file():
                            advanced_notes.append(f"图片像素级水印移除：已执行（{backend}）")
                            cleaned_path = pixel_path
                            combined += "\n\n【图片像素级移除】\n" + format_report(out_p, err_p)
                        else:
                            advanced_notes.append(f"图片像素级水印移除：执行失败，保留普通清理结果（{backend}）")
                            combined += "\n\n【图片像素级移除】失败：\n" + (err_p + "\n" + out_p).strip()
                    except Exception as e:
                        advanced_notes.append("图片像素级水印移除：异常，已跳过")
                else:
                    advanced_notes.append("图片像素级水印移除：未配置 NOAI_WATERMARK_DIR 或 MARKDIFFUSION_DIR，已跳过")
            elif options.get("pixel"):
                advanced_notes.append("图片像素级水印移除：仅适用于图片文件，已跳过")

            if advanced_notes:
                combined += "\n\n【高级选项说明】\n" + "\n".join("- " + n for n in advanced_notes)

            # 简单判断：清理报告里有没有“没有/无”或 actions 为空，展示状态
            low = (out_c or "").lower()
            if "still_has_c2pa" in low or "still_has_ai_metadata" in low:
                status = "有残留，请查看报告"
                status_cls = "warn"
            elif "removed=0" in low or (out_c and '"actions": []' in out_c):
                status = "未发现可移除项（可能本来就干净）"
                status_cls = "ok"
            else:
                status = "已清理"
                status_cls = "ok"

            results.append({
                "name": safe_name,
                "ok": True,
                "status": status,
                "status_cls": status_cls,
                "report": combined,
                "download_index": idx,
                "cleaned_path": str(cleaned_path),
            })
            success_count += 1

        with JOBS_LOCK:
            JOBS[token] = {
                "files": [
                    {"orig_name": r["name"], "cleaned_path": r["cleaned_path"]}
                    for r in results if r.get("cleaned_path")
                ],
                "created": time.time(),
            }

        # 生成逐文件报告 HTML
        files_html = []
        for idx, r in enumerate(results):
            name = html.escape(r["name"])
            if r["ok"]:
                badge = f'<span class="badge {r["status_cls"]}">{html.escape(r["status"])}</span>'
                link = f'<a href="/download/{token}/{idx}" style="font-size:.85rem">下载此文件</a>'
            else:
                badge = '<span class="badge error">失败</span>'
                link = ""
            files_html.append(
                f'<div style="border-top:1px solid var(--border);padding:12px 0">'
                f'<h4 style="margin:0 0 4px">{idx + 1}. {name} {badge} {link}</h4>'
                f'<pre>{html.escape(r["report"])}</pre>'
                f'</div>'
            )

        content = BATCH_RESULT_CONTENT.format(
            token=token,
            success_count=success_count,
            fail_count=fail_count,
            files_html="".join(files_html),
        )
        self._send_html(build_page(content))

    def _send_file(self, path: Path, download_name: str):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _download_name(self, orig_name: str):
        p = Path(orig_name)
        if p.suffix:
            return p.stem + ".cleaned" + p.suffix
        return orig_name + ".cleaned"

    def handle_download(self, token, index=None):
        with JOBS_LOCK:
            info = JOBS.get(token)
        if info is None:
            self._send_text("下载链接无效或已过期", 404)
            return
        files = info.get("files") or []
        if index is None:
            if len(files) == 1:
                path = Path(files[0]["cleaned_path"])
                if not path.is_file():
                    self._send_text("文件不存在", 404)
                    return
                self._send_file(path, self._download_name(files[0]["orig_name"]))
                return
            self.handle_download_all(token)
            return
        if index < 0 or index >= len(files):
            self._send_text("文件索引不存在", 404)
            return
        file_info = files[index]
        path = Path(file_info["cleaned_path"])
        if not path.is_file():
            self._send_text("文件不存在", 404)
            return
        self._send_file(path, self._download_name(file_info["orig_name"]))

    def handle_download_all(self, token):
        with JOBS_LOCK:
            info = JOBS.get(token)
        if info is None:
            self._send_text("下载链接无效或已过期", 404)
            return
        files = info.get("files") or []
        if not files:
            self._send_text("没有可下载的文件", 404)
            return
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
            for file_info in files:
                path = Path(file_info["cleaned_path"])
                if path.is_file():
                    zf.write(path, arcname=self._download_name(file_info["orig_name"]))
        data = buf.getvalue()
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Disposition", f'attachment; filename="cleaned_{token[:8]}.zip"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _parse_form(self, body):
        """Parse multipart/form-data.

        Returns:
            (uploads, options)
            uploads: [(filename, bytes), ...]
            options: {"rewrite": bool, "pixel": bool}
        """
        options = {"rewrite": False, "pixel": False}
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype:
            # 也允许直接原始文件上传（body 就是文件内容）
            return [("upload.bin", body)], options
        # email 解析器需要看到 MIME 头，这里补一个最小头部再解析 multipart body
        try:
            mime = b"MIME-Version: 1.0\r\nContent-Type: " + ctype.encode() + b"\r\n\r\n" + body
            msg = BytesParser(policy=policy.default).parsebytes(mime)
        except Exception as e:
            raise ValueError(f"multipart 解析失败: {e}")
        if not msg.is_multipart():
            # 某些客户端可能只发一个 part
            filename = msg.get_filename()
            if filename is None:
                raise ValueError("缺少文件名")
            return [(filename, (msg.get_payload(decode=True) or b""))], options
        uploads = []
        for part in msg.iter_parts():
            if part.get_content_disposition() == "form-data":
                name = part.get_param("name", header="content-disposition")
                if name == "file":
                    filename = part.get_filename()
                    if not filename:
                        raise ValueError("缺少文件名")
                    payload = part.get_payload(decode=True) or b""
                    uploads.append((filename, payload))
                elif name == "rewrite":
                    options["rewrite"] = True
                elif name == "pixel":
                    options["pixel"] = True
        return uploads, options


def cleanup_loop():
    while True:
        time.sleep(300)
        now = time.time()
        with JOBS_LOCK:
            expired = [k for k, v in JOBS.items() if now - v["created"] > CLEANUP_AGE_SECONDS]
            for k in expired:
                JOBS.pop(k, None)
        # 删除过期目录
        try:
            for child in PROCESSED_DIR.iterdir():
                if child.is_dir():
                    try:
                        mtime = child.stat().st_mtime
                        if now - mtime > CLEANUP_AGE_SECONDS:
                            shutil_rmtree(child)
                    except Exception:
                        pass
        except Exception:
            pass


def shutil_rmtree(path):
    import shutil
    shutil.rmtree(path, ignore_errors=True)


def main():
    import argparse
    parser = argparse.ArgumentParser(description="AI 水印移除小工具")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--open-browser", action="store_true")
    args = parser.parse_args()

    if not repo_ok():
        print("错误：没有找到 watermarks-remover 项目代码。")
        print(f"当前查找路径：{SCRIPTS_DIR}")
        print("请先运行 ./setup.sh 下载依赖，或设置 WATERMARKS_REMOVER_REPO 环境变量。")
        sys.exit(1)

    threading.Thread(target=cleanup_loop, daemon=True).start()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}"
    print("=" * 50)
    print("AI 水印移除小工具已启动")
    print(f"请在浏览器打开：{url}")
    print("按 Ctrl+C 停止服务")
    print("=" * 50)
    if args.open_browser:
        import webbrowser
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n已停止")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
