@chcp 65001 >nul & python -x "%~f0" %* & if "%CODEX_PURGE_NO_PAUSE%"=="1" exit /b & pause & exit /b
# -*- coding: utf-8 -*-
import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path


UUID_RE = re.compile(
    r"(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
)
DROP = object()


def extract_thread_id(text: str) -> str:
    match = UUID_RE.search(text.strip())
    if not match:
        raise ValueError("没有识别到合法线程 ID。")
    return match.group(1).lower()


def clean_json(value, thread_id):
    """删除以目标线程为主键的对象、键和精确列表项。"""
    if isinstance(value, dict):
        if value.get("id") == thread_id or value.get("threadId") == thread_id:
            return DROP
        result = {}
        for key, child in value.items():
            if thread_id in str(key).lower():
                continue
            cleaned = clean_json(child, thread_id)
            if cleaned is not DROP:
                result[key] = cleaned
        return result

    if isinstance(value, list):
        result = []
        for child in value:
            cleaned = clean_json(child, thread_id)
            if cleaned is not DROP:
                result.append(cleaned)
        return result

    if isinstance(value, str) and value.lower() in {
        thread_id,
        f"codex://threads/{thread_id}",
    }:
        return DROP

    return value


def atomic_write(path: Path, text: str):
    temp = path.with_name(path.name + ".thread-purge-tmp")
    temp.write_text(text, encoding="utf-8")
    os.replace(temp, path)


def stop_codex():
    script = r"""
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
    completed = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    output = completed.stdout.strip().splitlines()
    count = int(output[-1]) if output and output[-1].isdigit() else 0
    if count:
        print(f"[+] 已关闭 Codex 主进程：{count} 个")
        time.sleep(4)
    else:
        print("[*] Codex 未运行，直接清理。")


def start_codex():
    script = r"""
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
    completed = subprocess.run(
        ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if completed.returncode == 0:
        print("[+] 已重新启动 Codex。")
        return True
    print("[!] 自动启动 Codex 失败，请从开始菜单手动打开。")
    return False


def sqlite_tables(con):
    return [
        row[0]
        for row in con.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        ).fetchall()
    ]


def purge_sqlite(db: Path, thread_id: str):
    removed = 0
    try:
        con = sqlite3.connect(db, timeout=10)
        con.execute("PRAGMA foreign_keys=ON")

        for table in sqlite_tables(con):
            try:
                columns = [
                    row[1] for row in con.execute(f'PRAGMA table_info("{table}")').fetchall()
                ]
                if not columns:
                    continue
                where = " OR ".join(
                    f'instr(lower(CAST("{column}" AS TEXT)), ?) > 0'
                    for column in columns
                )
                match_count = con.execute(
                    f'SELECT COUNT(*) FROM "{table}" WHERE {where}',
                    [thread_id] * len(columns),
                ).fetchone()[0]
                if not match_count:
                    continue
                cursor = con.execute(
                    f'DELETE FROM "{table}" WHERE {where}',
                    [thread_id] * len(columns),
                )
                if cursor.rowcount > 0:
                    removed += cursor.rowcount
            except sqlite3.Error:
                # FTS、只读虚表或内部表跳过，继续清理其他表。
                pass

        con.commit()
        if removed:
            try:
                con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            except sqlite3.Error:
                pass
            try:
                con.execute("VACUUM")
            except sqlite3.Error:
                pass
        con.close()
        return removed, None
    except sqlite3.Error as exc:
        return removed, str(exc)


def metadata_json_files(root: Path):
    paths = {
        root / ".codex-global-state.json",
        root / ".codex-global-state.json.bak",
        root / ".codex-global-state.json.bak.bak",
    }
    backup_root = root / "backups_state"
    if backup_root.exists():
        paths.update(backup_root.rglob(".codex-global-state.json"))
        paths.update(backup_root.rglob(".codex-global-state.json.bak"))
    return sorted(path for path in paths if path.exists())


def session_index_files(root: Path):
    paths = {
        root / "session_index.jsonl",
        root / "session_index.jsonl.bak",
    }
    backup_root = root / "backups_state"
    if backup_root.exists():
        paths.update(backup_root.rglob("session_index.jsonl"))
        paths.update(backup_root.rglob("session_index.jsonl.bak"))
    return sorted(path for path in paths if path.exists())


def purge_metadata_files(root: Path, thread_id: str):
    changed = []

    for path in metadata_json_files(root):
        try:
            raw = path.read_text(encoding="utf-8")
            if thread_id not in raw.lower():
                continue
            data = json.loads(raw)
            cleaned = clean_json(data, thread_id)
            atomic_write(
                path,
                json.dumps(cleaned, ensure_ascii=False, separators=(",", ":")),
            )
            changed.append(path)
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            print(f"[!] JSON 跳过：{path} ({exc})")

    for path in session_index_files(root):
        try:
            raw = path.read_text(encoding="utf-8", errors="replace")
            if thread_id not in raw.lower():
                continue
            kept = [line for line in raw.splitlines() if thread_id not in line.lower()]
            atomic_write(path, "\n".join(kept) + ("\n" if kept else ""))
            changed.append(path)
        except OSError as exc:
            print(f"[!] JSONL 跳过：{path} ({exc})")

    return changed


def purge_named_artifacts(root: Path, thread_id: str):
    removed = []
    roots = [
        root / "sessions",
        root / "archived_sessions",
        root / "thread-writer-locks",
    ]
    root_resolved = root.resolve()

    for base in roots:
        if not base.exists():
            continue
        candidates = sorted(
            (p for p in base.rglob("*") if thread_id in p.name.lower()),
            key=lambda p: len(p.parts),
            reverse=True,
        )
        for path in candidates:
            resolved = path.resolve()
            if root_resolved not in resolved.parents:
                raise RuntimeError(f"目标越出 .codex，已拒绝删除：{resolved}")
            try:
                if path.is_dir():
                    shutil.rmtree(path)
                elif path.exists():
                    path.unlink()
                removed.append(path)
            except OSError as exc:
                print(f"[!] 文件删除失败：{path} ({exc})")
    return removed


def find_authoritative_refs(root: Path, thread_id: str):
    refs = []
    dbs = sorted({*root.rglob("*.sqlite"), *root.rglob("*.db")})
    for db in dbs:
        try:
            con = sqlite3.connect(f"file:{db.as_posix()}?mode=ro", uri=True, timeout=3)
            for table in sqlite_tables(con):
                columns = [
                    row[1] for row in con.execute(f'PRAGMA table_info("{table}")').fetchall()
                ]
                for column in columns:
                    try:
                        count = con.execute(
                            f'SELECT COUNT(*) FROM "{table}" '
                            f'WHERE instr(lower(CAST("{column}" AS TEXT)), ?) > 0',
                            (thread_id,),
                        ).fetchone()[0]
                        if count:
                            refs.append(f"{db} :: {table}.{column} ({count})")
                    except sqlite3.Error:
                        pass
            con.close()
        except sqlite3.Error:
            pass

    for path in metadata_json_files(root) + session_index_files(root):
        try:
            if thread_id in path.read_text(encoding="utf-8", errors="replace").lower():
                refs.append(str(path))
        except OSError:
            pass

    return refs


def delete_once(args):
    print("=" * 66)
    print(" Codex 损坏对话深度删除器")
    print(" 支持：codex://threads/UUID 或直接输入 UUID")
    print("=" * 66)

    text = args.target or input("\n粘贴对话深度链接：").strip()
    try:
        thread_id = extract_thread_id(text)
    except ValueError as exc:
        print(f"\n[错误] {exc}")
        return 2

    codex_root = Path.home() / ".codex"
    if not codex_root.is_dir():
        print(f"\n[错误] Codex 数据目录不存在：{codex_root}")
        return 3

    print(f"\n目标线程：{thread_id}")
    print("动作：删除会话文件、数据库行、摘要、项目映射和备份索引。")
    print("提示：会先关闭 Codex，避免内存缓存把坏记录重新写回来。")

    if not args.yes:
        confirm = input("\n按回车确认彻底删除；输入其他任意内容取消：").strip()
        if confirm:
            print("\n[-] 已取消，未修改任何数据。")
            return 10

    if not args.no_close:
        stop_codex()

    db_removed = 0
    db_errors = []
    databases = sorted({*codex_root.rglob("*.sqlite"), *codex_root.rglob("*.db")})
    for db in databases:
        removed, error = purge_sqlite(db, thread_id)
        db_removed += removed
        if removed:
            print(f"[+] 数据库删除 {removed:>3} 行：{db}")
        if error:
            db_errors.append(f"{db}: {error}")

    changed_metadata = purge_metadata_files(codex_root, thread_id)
    for path in changed_metadata:
        print(f"[+] 清理索引：{path}")

    removed_artifacts = purge_named_artifacts(codex_root, thread_id)
    for path in removed_artifacts:
        print(f"[+] 删除会话文件：{path}")

    refs = find_authoritative_refs(codex_root, thread_id)

    print("\n" + "-" * 66)
    print(f"数据库删除行数：{db_removed}")
    print(f"修改索引文件数：{len(changed_metadata)}")
    print(f"删除会话文件数：{len(removed_artifacts)}")

    if db_errors:
        print(f"数据库跳过数：{len(db_errors)}")
        for error in db_errors:
            print(f"  [!] {error}")

    if refs:
        print("\n[警告] 仍发现权威索引引用：")
        for ref in refs:
            print(f"  - {ref}")
        print("请确认 Codex 已完全退出，再重新运行一次。")
        return 4

    print("\n[完成] 损坏对话已从本地权威记录中彻底删除。")
    print("现在可以重新打开 Codex。")
    return 0


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("target", nargs="?")
    parser.add_argument("--yes", action="store_true")
    parser.add_argument("--no-close", action="store_true")
    args, _ = parser.parse_known_args()
    interactive = args.target is None

    while True:
        result = delete_once(args)

        if result == 0 and not args.no_close:
            start_codex()

        if not interactive:
            return 0 if result == 10 else result

        if result == 0:
            print("\n[*] 删除完成，1 秒后返回初始界面，可继续删除下一条对话。")
            time.sleep(1)
        else:
            print("\n[*] 1 秒后返回初始界面。")
            time.sleep(1)

        os.system("cls")
        args.target = None
        args.yes = False


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[-] 用户取消。")
        raise SystemExit(130)
    except Exception as exc:
        print(f"\n[异常] {type(exc).__name__}: {exc}")
        raise SystemExit(1)
