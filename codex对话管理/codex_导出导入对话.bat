@echo off & chcp 65001 >nul & title Codex Thread Export Import & python -x "%~f0" %* & echo. & echo Press any key to close... & pause >nul & exit /b
# -*- coding: utf-8 -*-
import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import sys
import time
import traceback
import uuid
import zipfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath


FORMAT_NAME = "codex-local-thread-export"
FORMAT_VERSION = 1
UUID_RE = re.compile(
    r"(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
)
ATTACHMENT_RE = re.compile(
    r"(?i)(?:^|[\\/])attachments[\\/]+([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
)


def utc_iso():
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def uuid7():
    timestamp_ms = int(time.time() * 1000) & ((1 << 48) - 1)
    rand_a = secrets.randbits(12)
    rand_b = secrets.randbits(62)
    value = (
        (timestamp_ms << 80)
        | (0x7 << 76)
        | (rand_a << 64)
        | (0b10 << 62)
        | rand_b
    )
    return str(uuid.UUID(int=value))


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sanitize_filename(value):
    value = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", value).strip(" .")
    return value[:80] or "Codex_Thread"


def next_export_path(program_dir, title):
    base = sanitize_filename(title)
    package = program_dir / f"{base}_导出.codexthread.zip"
    index = 2
    while package.exists():
        package = program_dir / f"{base}_导出_{index}.codexthread.zip"
        index += 1
    return package


def extract_thread_id(value):
    match = UUID_RE.search(value.strip())
    if not match:
        raise ValueError("没有识别到合法线程 ID。")
    return match.group(1).lower()


def strip_quotes(value):
    return value.strip().strip('"').strip("'")


def stop_codex():
    ps = r"""
$targets = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -eq 'ChatGPT.exe' -and
        $_.ExecutablePath -like '*OpenAI.Codex_*'
    }
$count = @($targets).Count
$targets | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}
Write-Output $count
"""
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    lines = result.stdout.strip().splitlines()
    count = int(lines[-1]) if lines and lines[-1].isdigit() else 0
    if count:
        print(f"[+] 已关闭 Codex 主进程：{count} 个")
        time.sleep(4)
    else:
        print("[*] Codex 当前未运行。")


def start_codex():
    ps = r"""
$app = Get-StartApps -ErrorAction SilentlyContinue |
    Where-Object { $_.AppID -like 'OpenAI.Codex_*!App' } |
    Select-Object -First 1
if ($app) {
    Start-Process explorer.exe -ArgumentList ('shell:AppsFolder\' + $app.AppID)
    Write-Output $app.AppID
    exit 0
}
$pkg = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($pkg) {
    $appId = $pkg.PackageFamilyName + '!App'
    Start-Process explorer.exe -ArgumentList ('shell:AppsFolder\' + $appId)
    Write-Output $appId
    exit 0
}
exit 1
"""
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode == 0:
        print("[+] 已重新启动 Codex。")
        return True
    print("[!] 自动启动 Codex 失败，请从开始菜单手动打开。")
    return False


def sqlite_row_dict(con, table, where, params):
    con.row_factory = sqlite3.Row
    row = con.execute(f'SELECT * FROM "{table}" WHERE {where}', params).fetchone()
    return dict(row) if row else None


def valid_rollout_snapshot(path):
    best_prefix = b""
    best_omitted = 0
    best_bad_line = 0

    # Codex appends one JSON object per line.  Reading an active conversation can
    # catch the final object halfway through its write.  Keep retrying, then use
    # the longest completely parsed prefix instead of failing the whole export.
    for attempt in range(8):
        data = path.read_bytes()
        try:
            if not data:
                raise ValueError("空会话文件")

            valid_end = 0
            bad_line = 0
            for line_no, raw_line in enumerate(data.splitlines(keepends=True), 1):
                payload = raw_line.rstrip(b"\r\n")
                if not payload:
                    raise ValueError(f"第 {line_no} 行为空")
                try:
                    json.loads(payload.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError):
                    bad_line = line_no
                    break
                valid_end += len(raw_line)

            if not bad_line:
                return data

            prefix = data[:valid_end]
            if len(prefix) > len(best_prefix):
                best_prefix = prefix
                best_omitted = len(data) - valid_end
                best_bad_line = bad_line
        except ValueError:
            pass
        time.sleep(0.35)

    if best_prefix:
        print(
            f"[!] 会话仍在写入：已安全截取到第 {best_bad_line - 1} 行，"
            f"忽略末尾未写完的 {best_omitted} 字节。"
        )
        return best_prefix

    raise RuntimeError("会话 JSONL 从第一行起就损坏，无法生成有效导出包。")


def collect_attachment_ids(rollout_bytes):
    ids = set()
    # Do not use str.splitlines(): JSON strings may legally contain U+2028/U+2029,
    # which splitlines() mistakes for record separators. JSONL records are split
    # only by the actual LF byte written by Codex.
    for line in rollout_bytes.decode("utf-8").split("\n"):
        line = line.removesuffix("\r")
        if not line:
            continue
        obj = json.loads(line)
        stack = [obj]
        while stack:
            value = stack.pop()
            if isinstance(value, dict):
                stack.extend(value.values())
            elif isinstance(value, list):
                stack.extend(value)
            elif isinstance(value, str):
                ids.update(x.lower() for x in ATTACHMENT_RE.findall(value))
    return sorted(ids)


def add_directory_to_zip(zf, source_dir, archive_root):
    count = 0
    for path in source_dir.rglob("*"):
        if path.is_file():
            rel = path.relative_to(source_dir)
            zf.write(path, str(PurePosixPath(archive_root) / PurePosixPath(rel.as_posix())))
            count += 1
    return count


def export_thread(root, program_dir, target):
    thread_id = extract_thread_id(target)
    state_db = root / "state_5.sqlite"
    if not state_db.exists():
        raise RuntimeError(f"找不到状态数据库：{state_db}")

    con = sqlite3.connect(state_db, timeout=10)
    row = sqlite_row_dict(con, "threads", "id=?", (thread_id,))
    dynamic_tools = []
    try:
        con.row_factory = sqlite3.Row
        dynamic_tools = [
            dict(x)
            for x in con.execute(
                "SELECT * FROM thread_dynamic_tools WHERE thread_id=? ORDER BY position",
                (thread_id,),
            ).fetchall()
        ]
    except sqlite3.Error:
        pass
    con.close()

    if row is None:
        raise RuntimeError("state_5.sqlite 中没有这个线程。")
    rollout = Path(row["rollout_path"])
    if not rollout.is_file():
        matches = list((root / "sessions").rglob(f"*{thread_id}*.jsonl"))
        matches += list((root / "archived_sessions").rglob(f"*{thread_id}*.jsonl"))
        if len(matches) != 1:
            raise RuntimeError(f"无法唯一定位会话 JSONL，匹配数：{len(matches)}")
        rollout = matches[0]

    rollout_bytes = valid_rollout_snapshot(rollout)
    attachment_ids = collect_attachment_ids(rollout_bytes)

    visualization_dirs = []
    visualization_root = root / "visualizations"
    if visualization_root.exists():
        visualization_dirs = [
            p for p in visualization_root.rglob(thread_id) if p.is_dir()
        ]

    title = row.get("title") or thread_id
    export_dir = program_dir / "对话管理"
    export_dir.mkdir(parents=True, exist_ok=True)
    package = next_export_path(export_dir, title)

    manifest = {
        "format": FORMAT_NAME,
        "format_version": FORMAT_VERSION,
        "exported_at": utc_iso(),
        "source_codex_root": str(root),
        "source_thread_id": thread_id,
        "title": title,
        "rollout_sha256": sha256_bytes(rollout_bytes),
        "rollout_size": len(rollout_bytes),
        "thread_row": row,
        "dynamic_tools": dynamic_tools,
        "attachment_ids": attachment_ids,
        "visualizations": [],
    }

    with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        zf.writestr("rollout.jsonl", rollout_bytes)

        attachment_files = 0
        for attachment_id in attachment_ids:
            source_dir = root / "attachments" / attachment_id
            if source_dir.is_dir():
                attachment_files += add_directory_to_zip(
                    zf, source_dir, f"attachments/{attachment_id}"
                )

        visualization_files = 0
        for index, source_dir in enumerate(visualization_dirs):
            archive_root = f"visualizations/{index}"
            visualization_files += add_directory_to_zip(zf, source_dir, archive_root)
            manifest["visualizations"].append(
                {"old_path": str(source_dir), "archive_root": archive_root}
            )

        manifest["attachment_file_count"] = attachment_files
        manifest["visualization_file_count"] = visualization_files
        zf.writestr(
            "manifest.json",
            json.dumps(manifest, ensure_ascii=False, indent=2).encode("utf-8"),
        )

    with zipfile.ZipFile(package, "r") as zf:
        bad = zf.testzip()
        if bad:
            package.unlink(missing_ok=True)
            raise RuntimeError(f"ZIP 自检失败：{bad}")

    print(f"\n[完成] 已导出：{package}")
    print(f"线程：{title}")
    print(f"会话大小：{len(rollout_bytes)} 字节")
    print(f"附件文件：{manifest['attachment_file_count']}")
    print(f"可视化文件：{manifest['visualization_file_count']}")
    return package


def recursive_replace(value, replacements):
    if isinstance(value, dict):
        return {key: recursive_replace(child, replacements) for key, child in value.items()}
    if isinstance(value, list):
        return [recursive_replace(child, replacements) for child in value]
    if isinstance(value, str):
        for old, new in replacements:
            value = value.replace(old, new)
        return value
    return value


def safe_extract_member(zf, member, destination):
    relative = PurePosixPath(member.filename)
    if relative.is_absolute() or ".." in relative.parts:
        raise RuntimeError(f"ZIP 含不安全路径：{member.filename}")
    target = destination.joinpath(*relative.parts)
    target_resolved = target.resolve()
    destination_resolved = destination.resolve()
    if target_resolved != destination_resolved and destination_resolved not in target_resolved.parents:
        raise RuntimeError(f"ZIP 路径越界：{member.filename}")
    if member.is_dir():
        target.mkdir(parents=True, exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        with zf.open(member, "r") as source, target.open("wb") as output:
            shutil.copyfileobj(source, output)
    return target


def append_session_index(root, thread_id, title):
    path = root / "session_index.jsonl"
    record = {
        "id": thread_id,
        "thread_name": title,
        "updated_at": utc_iso(),
    }
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")


def update_global_state(root, thread_id, output_dir, title):
    path = root / ".codex-global-state.json"
    if not path.exists():
        return
    data = json.loads(path.read_text(encoding="utf-8"))
    projectless = data.setdefault("projectless-thread-ids", [])
    if thread_id not in projectless:
        projectless.append(thread_id)

    assignments = data.setdefault("thread-project-assignments", {})
    assignments.pop(thread_id, None)

    data.setdefault("thread-projectless-output-directories", {})[thread_id] = str(output_dir)

    atom = data.setdefault("electron-persisted-atom-state", {})
    atom.setdefault("thread-descriptions-v1", {})[thread_id] = f"导入副本：{title}"

    temp = path.with_name(path.name + ".import-tmp")
    temp.write_text(
        json.dumps(data, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    os.replace(temp, path)


def insert_catalog(root, old_id, new_id, title, cwd, now_s):
    db = root / "sqlite" / "codex-dev.db"
    if not db.exists():
        return
    con = sqlite3.connect(db, timeout=10)
    con.row_factory = sqlite3.Row
    source = con.execute(
        "SELECT * FROM local_thread_catalog WHERE host_id='local' AND thread_id=?",
        (old_id,),
    ).fetchone()
    values = dict(source) if source else {
        "host_id": "local",
        "thread_id": new_id,
        "display_title": title,
        "source_created_at": now_s,
        "source_updated_at": now_s,
        "cwd": str(cwd),
        "source_kind": "vscode",
        "source_detail": None,
        "model_provider": "openai",
        "git_branch": None,
        "missing_candidate": 0,
        "thread_source": "user",
        "source_recency_at": now_s,
        "pending_observed_title": 0,
    }
    values.update(
        {
            "host_id": "local",
            "thread_id": new_id,
            "display_title": title,
            "source_created_at": now_s,
            "source_updated_at": now_s,
            "source_recency_at": now_s,
            "cwd": str(cwd),
            "missing_candidate": 0,
            "pending_observed_title": 0,
        }
    )
    try:
        sequence = con.execute(
            "SELECT COALESCE(MAX(observation_sequence),0)+1 FROM local_thread_catalog"
        ).fetchone()[0]
        values["observation_sequence"] = sequence
        current_columns = [
            x[1] for x in con.execute("PRAGMA table_info(local_thread_catalog)").fetchall()
        ]
        values = {key: values[key] for key in current_columns if key in values}
        columns = list(values)
        con.execute(
            f'INSERT INTO local_thread_catalog ({",".join(columns)}) '
            f'VALUES ({",".join("?" for _ in columns)})',
            [values[x] for x in columns],
        )
        con.commit()
        try:
            con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error:
            pass
    finally:
        con.close()


def import_thread(root, program_dir, package, no_close=False):
    package = Path(package).expanduser().resolve()
    if not package.is_file():
        raise RuntimeError(f"导入包不存在：{package}")

    with zipfile.ZipFile(package, "r") as zf:
        bad = zf.testzip()
        if bad:
            raise RuntimeError(f"ZIP 损坏：{bad}")
        manifest = json.loads(zf.read("manifest.json").decode("utf-8"))
        rollout_bytes = zf.read("rollout.jsonl")

    if manifest.get("format") != FORMAT_NAME or manifest.get("format_version") != FORMAT_VERSION:
        raise RuntimeError("不是兼容的 Codex 对话导出包。")
    if sha256_bytes(rollout_bytes) != manifest.get("rollout_sha256"):
        raise RuntimeError("rollout.jsonl 哈希校验失败。")

    old_id = manifest["source_thread_id"].lower()
    new_id = uuid7()
    title = (manifest.get("title") or old_id) + "（导入副本）"
    now = datetime.now()
    now_s = int(time.time())
    now_ms = int(time.time() * 1000)

    if not no_close:
        stop_codex()

    state_db = root / "state_5.sqlite"
    if not state_db.exists():
        raise RuntimeError(f"找不到状态数据库：{state_db}")

    con = sqlite3.connect(state_db, timeout=15)
    if con.execute("SELECT 1 FROM threads WHERE id=?", (new_id,)).fetchone():
        con.close()
        raise RuntimeError("新 UUID 意外冲突，请重试。")

    backup = program_dir / f"state_5_before_thread_import_{now.strftime('%Y%m%d_%H%M%S')}.sqlite"
    backup_con = sqlite3.connect(backup)
    con.backup(backup_con)
    backup_con.close()

    default_codex_root = (Path.home() / ".codex").resolve()
    projectless_root = (
        Path.home() / "Documents" / "Codex" / "Imported"
        if root.resolve() == default_codex_root
        else root / "projectless_outputs"
    )
    output_dir = projectless_root / new_id / "outputs"
    output_dir.mkdir(parents=True, exist_ok=True)

    attachment_map = {}
    replacements = [(old_id, new_id)]
    extracted_dirs = []

    try:
        with zipfile.ZipFile(package, "r") as zf:
            for old_attachment_id in manifest.get("attachment_ids", []):
                prefix = f"attachments/{old_attachment_id}/"
                members = [x for x in zf.infolist() if x.filename.startswith(prefix)]
                if not members:
                    continue
                new_attachment_id = str(uuid.uuid4())
                destination = root / "attachments" / new_attachment_id
                destination.mkdir(parents=True, exist_ok=False)
                extracted_dirs.append(destination)
                for member in members:
                    relative_name = member.filename[len(prefix):]
                    if not relative_name:
                        continue
                    clone = zipfile.ZipInfo(relative_name)
                    clone.external_attr = member.external_attr
                    clone.compress_type = member.compress_type
                    clone.file_size = member.file_size
                    data = zf.read(member)
                    target = destination.joinpath(*PurePosixPath(relative_name).parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(data)
                attachment_map[old_attachment_id] = new_attachment_id
                replacements.append((old_attachment_id, new_attachment_id))

            for index, item in enumerate(manifest.get("visualizations", [])):
                archive_root = item["archive_root"].rstrip("/") + "/"
                members = [x for x in zf.infolist() if x.filename.startswith(archive_root)]
                if not members:
                    continue
                destination = root / "visualizations" / "Imported" / new_id / str(index)
                destination.mkdir(parents=True, exist_ok=False)
                extracted_dirs.append(destination)
                for member in members:
                    relative_name = member.filename[len(archive_root):]
                    if not relative_name:
                        continue
                    target = destination.joinpath(*PurePosixPath(relative_name).parts)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(zf.read(member))
                replacements.append((item["old_path"], str(destination)))

        imported_lines = []
        jsonl_lines = []
        for line in rollout_bytes.decode("utf-8").split("\n"):
            line = line.removesuffix("\r")
            if line:
                jsonl_lines.append(line)

        for index, line in enumerate(jsonl_lines):
            obj = recursive_replace(json.loads(line), replacements)
            if index == 0 and obj.get("type") == "session_meta":
                payload = obj.setdefault("payload", {})
                payload["id"] = new_id
                payload["session_id"] = new_id
                payload["cwd"] = str(output_dir)
                payload["timestamp"] = utc_iso()
                if isinstance(payload.get("context_window"), dict):
                    payload["context_window"]["window_id"] = uuid7()
                obj["timestamp"] = payload["timestamp"]
            imported_lines.append(json.dumps(obj, ensure_ascii=False, separators=(",", ":")))

        new_rollout_bytes = ("\n".join(imported_lines) + "\n").encode("utf-8")
        session_dir = root / "sessions" / now.strftime("%Y") / now.strftime("%m") / now.strftime("%d")
        session_dir.mkdir(parents=True, exist_ok=True)
        rollout_path = session_dir / f"rollout-{now.strftime('%Y-%m-%dT%H-%M-%S')}-{new_id}.jsonl"
        if rollout_path.exists():
            raise RuntimeError(f"目标会话文件已存在：{rollout_path}")
        rollout_path.write_bytes(new_rollout_bytes)

        source_row = dict(manifest["thread_row"])
        source_row.update(
            {
                "id": new_id,
                "rollout_path": str(rollout_path),
                "created_at": now_s,
                "updated_at": now_s,
                "cwd": str(output_dir),
                "title": title,
                "archived": 0,
                "archived_at": None,
                "git_sha": None,
                "git_branch": None,
                "git_origin_url": None,
                "created_at_ms": now_ms,
                "updated_at_ms": now_ms,
                "recency_at": now_s,
                "recency_at_ms": now_ms,
                "is_pinned": 0,
                "thread_section_id": None,
                "section_position": None,
                "section_entered_at_ms": None,
            }
        )

        current_columns = [x[1] for x in con.execute("PRAGMA table_info(threads)").fetchall()]
        insert_values = {key: source_row[key] for key in current_columns if key in source_row}
        columns = list(insert_values)
        con.execute("PRAGMA foreign_keys=ON")
        con.execute("BEGIN IMMEDIATE")
        con.execute(
            f'INSERT INTO threads ({",".join(columns)}) VALUES ({",".join("?" for _ in columns)})',
            [insert_values[x] for x in columns],
        )

        dynamic_columns = [
            x[1] for x in con.execute("PRAGMA table_info(thread_dynamic_tools)").fetchall()
        ]
        for tool in manifest.get("dynamic_tools", []):
            tool = dict(tool)
            tool["thread_id"] = new_id
            values = {key: tool[key] for key in dynamic_columns if key in tool}
            if values:
                cols = list(values)
                con.execute(
                    f'INSERT INTO thread_dynamic_tools ({",".join(cols)}) VALUES ({",".join("?" for _ in cols)})',
                    [values[x] for x in cols],
                )
        con.commit()
        try:
            con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        except sqlite3.Error:
            pass
        con.close()

        insert_catalog(root, old_id, new_id, title, output_dir, now_s)
        append_session_index(root, new_id, title)
        update_global_state(root, new_id, output_dir, title)

    except Exception:
        try:
            con.rollback()
            con.close()
        except Exception:
            pass
        for path in reversed(extracted_dirs):
            if path.exists():
                shutil.rmtree(path)
        raise

    print("\n[完成] 对话已作为全新项目外线程导入。")
    print(f"新线程 ID：{new_id}")
    print(f"深度链接：codex://threads/{new_id}")
    print(f"标题：{title}")
    print(f"会话文件：{rollout_path}")
    print(f"状态库备份：{backup}")
    print("项目归属：无；可在 Codex 中手动拖动到项目。")
    if not no_close:
        start_codex()
    return new_id


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("action", nargs="?")
    parser.add_argument("value", nargs="?")
    parser.add_argument("--root")
    parser.add_argument("--no-close", action="store_true")
    args, _ = parser.parse_known_args()

    root = Path(args.root).expanduser().resolve() if args.root else Path.home() / ".codex"
    program_dir = Path(__file__).resolve().parent
    interactive = args.action is None

    while True:
        print("=" * 72)
        print(" Codex 对话完整导出 / 独立副本导入工具")
        print("=" * 72)
        print("1. 导出对话")
        print("2. 导入为全新项目外对话")

        action = (args.action or input("\n请选择 1/2：").strip()).lower()
        result = 0

        try:
            if action in {"1", "export", "e"}:
                target = args.value or input("粘贴 codex://threads/...：").strip()
                export_thread(root, program_dir, target)

            elif action in {"2", "import", "i"}:
                value = args.value or input("拖入或粘贴 .codexthread.zip 路径：").strip()
                package = strip_quotes(value)
                print("\n导入一定生成新 UUID，不覆盖原对话。")
                confirm = input("按回车确认导入；输入其他任意内容取消：").strip() if not args.value else ""
                if confirm:
                    print("[-] 已取消。")
                else:
                    import_thread(root, program_dir, package, no_close=args.no_close)

            else:
                print("[错误] 请选择 1 或 2。")
                result = 2
        except Exception as exc:
            print(f"\n[异常] {type(exc).__name__}: {exc}")
            log_path = program_dir / "Codex_Thread_Export_Import_error.log"
            log_path.write_text(
                f"time={utc_iso()}\n"
                f"error={type(exc).__name__}: {exc}\n\n"
                f"{traceback.format_exc()}",
                encoding="utf-8",
            )
            print(f"完整错误日志：{log_path}")
            if action in {"2", "import", "i"} and not args.no_close:
                start_codex()
            result = 1
            if not interactive:
                return result

        if not interactive:
            return result

        print("\n[*] 1 秒后返回初始界面。")
        time.sleep(1)
        os.system("cls")
        args.action = None
        args.value = None


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[-] 用户取消。")
        raise SystemExit(130)
    except Exception as exc:
        print(f"\n[异常] {type(exc).__name__}: {exc}")
        log_path = Path(__file__).resolve().parent / "Codex_Thread_Export_Import_error.log"
        log_path.write_text(
            f"time={utc_iso()}\n"
            f"error={type(exc).__name__}: {exc}\n\n"
            f"{traceback.format_exc()}",
            encoding="utf-8",
        )
        print(f"完整错误日志：{log_path}")
        raise SystemExit(1)
