"""SSH/SFTP client for remote Moodle backup operations."""

from __future__ import annotations

import os
import re
import shutil
import stat
import threading
from pathlib import Path, PurePosixPath
from typing import Callable

import paramiko

LogCallback = Callable[[str], None]
ProgressCallback = Callable[[int, str], None]

# YYYY-MM-DD_HH-MM-SS — same naming as moodle-backup.sh / remote list
BACKUP_DIR_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$")


def is_backup_dir_name(name: str) -> bool:
    return bool(BACKUP_DIR_NAME.match(name))


class SSHClient:
    def __init__(
        self,
        host: str,
        username: str,
        password: str,
        port: int = 22,
        private_key_path: Path | None = None,
    ) -> None:
        self.host = host
        self.username = username
        self.password = password
        self.port = port
        self.private_key_path = private_key_path
        self._client: paramiko.SSHClient | None = None
        self.auth_method: str = ""

    def connect(self, *, force_password: bool = False) -> None:
        self.close()
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        if (
            not force_password
            and self.private_key_path
            and self.private_key_path.is_file()
        ):
            from gui.ssh_keys import load_private_key

            try:
                pkey = load_private_key(self.private_key_path)
                client.connect(
                    self.host,
                    port=self.port,
                    username=self.username,
                    pkey=pkey,
                    timeout=30,
                    allow_agent=False,
                    look_for_keys=False,
                )
                self._client = client
                self.auth_method = "key"
                return
            except Exception:
                client.close()
                client = paramiko.SSHClient()
                client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        if not self.password:
            raise RuntimeError("SSH authentication failed: key unavailable and password is empty")

        client.connect(
            self.host,
            port=self.port,
            username=self.username,
            password=self.password,
            timeout=30,
            allow_agent=False,
            look_for_keys=False,
        )
        self._client = client
        self.auth_method = "password"

    def close(self) -> None:
        if self._client:
            self._client.close()
            self._client = None

    def _ensure(self) -> paramiko.SSHClient:
        if not self._client:
            raise RuntimeError("Not connected")
        return self._client

    def test_connection(self) -> str:
        self.connect()
        out, err, code = self.exec("echo ok && uname -a")
        if code != 0:
            raise RuntimeError(err or "Connection test failed")
        return out.strip()

    def exec(self, command: str) -> tuple[str, str, int]:
        client = self._ensure()
        _, stdout, stderr = client.exec_command(command, get_pty=True)
        out = stdout.read().decode("utf-8", errors="replace")
        err = stderr.read().decode("utf-8", errors="replace")
        code = stdout.channel.recv_exit_status()
        return out, err, code

    def exec_stream(
        self,
        command: str,
        on_line: LogCallback,
        on_done: Callable[[int], None] | None = None,
    ) -> threading.Thread:
        client = self._ensure()

        def _run() -> None:
            _, stdout, stderr = client.exec_command(command, get_pty=True)
            channel = stdout.channel

            while not channel.exit_status_ready():
                if channel.recv_ready():
                    data = channel.recv(4096).decode("utf-8", errors="replace")
                    for line in data.splitlines():
                        on_line(line)
                if channel.recv_stderr_ready():
                    data = channel.recv_stderr(4096).decode("utf-8", errors="replace")
                    for line in data.splitlines():
                        on_line(line)

            while channel.recv_ready():
                data = channel.recv(4096).decode("utf-8", errors="replace")
                for line in data.splitlines():
                    on_line(line)

            code = channel.recv_exit_status()
            if on_done:
                on_done(code)

        thread = threading.Thread(target=_run, daemon=True)
        thread.start()
        return thread

    def expand_path(self, path: str) -> str:
        """Expand ~ and env vars on the remote host."""
        quoted = path.replace("'", "'\"'\"'")
        out, err, code = self.exec(f"bash -lc 'echo {quoted}'")
        if code != 0:
            raise RuntimeError(f"Failed to expand path {path!r}: {err or out}")
        lines = [line.strip().replace("\r", "") for line in out.splitlines() if line.strip()]
        if not lines:
            return path
        return lines[-1]

    def mkdir_p(self, remote_path: str) -> None:
        expanded = self.expand_path(remote_path)
        _, err, code = self.exec(f'mkdir -p "{expanded}"')
        if code != 0:
            raise RuntimeError(f"mkdir failed for {expanded}: {err}")

    def _sftp(self) -> paramiko.SFTPClient:
        client = self._ensure()
        transport = client.get_transport()
        if not transport:
            raise RuntimeError("SSH transport not available")
        return paramiko.SFTPClient.from_transport(transport)

    def _sftp_mkdir_p(self, sftp: paramiko.SFTPClient, remote_dir: str) -> None:
        remote_dir = remote_dir.replace("\\", "/")
        if remote_dir in ("", "/"):
            return
        parts = PurePosixPath(remote_dir).parts
        current = ""
        for part in parts:
            if part == "/":
                current = "/"
                continue
            current = f"{current}/{part}" if current else part
            try:
                sftp.stat(current)
            except OSError:
                sftp.mkdir(current)

    @staticmethod
    def _normalize_text_upload(local: Path) -> Path:
        """Ensure shell/PHP scripts use Unix LF line endings before upload."""
        if local.suffix not in (".sh", ".php"):
            return local
        text = local.read_text(encoding="utf-8")
        normalized = text.replace("\r\n", "\n").replace("\r", "\n")
        if normalized == text:
            return local
        tmp = Path(os.environ.get("TEMP", "/tmp")) / f"moobackup_{local.name}"
        tmp.write_text(normalized, encoding="utf-8", newline="\n")
        return tmp

    def upload_file(self, local: Path, remote: str) -> None:
        if not local.is_file():
            raise FileNotFoundError(f"Local file not found: {local}")
        upload_path = self._normalize_text_upload(local)
        remote_expanded = self.expand_path(remote)
        parent = str(PurePosixPath(remote_expanded).parent)
        sftp = self._sftp()
        try:
            self._sftp_mkdir_p(sftp, parent)
            sftp.put(str(upload_path), remote_expanded)
        finally:
            sftp.close()
        if upload_path != local:
            upload_path.unlink(missing_ok=True)

    def _list_remote_files(
        self,
        sftp: paramiko.SFTPClient,
        remote_path: str,
        base: str = "",
    ) -> list[tuple[str, str, int]]:
        files: list[tuple[str, str, int]] = []
        for entry in sftp.listdir_attr(remote_path):
            remote_item = f"{remote_path}/{entry.filename}"
            rel = f"{base}/{entry.filename}" if base else entry.filename
            if stat.S_ISDIR(entry.st_mode):
                files.extend(self._list_remote_files(sftp, remote_item, rel))
            else:
                files.append((remote_item, rel, int(entry.st_size or 0)))
        return files

    @staticmethod
    def _list_local_files(local_dir: Path, base: Path | None = None) -> list[tuple[Path, str, int]]:
        root = base or local_dir
        files: list[tuple[Path, str, int]] = []
        for item in local_dir.rglob("*"):
            if item.is_file():
                rel = item.relative_to(root).as_posix()
                files.append((item, rel, item.stat().st_size))
        return files

    def download_dir(
        self,
        remote_dir: str,
        local_dir: Path,
        on_progress: ProgressCallback | None = None,
    ) -> None:
        remote_expanded = self.expand_path(remote_dir)
        local_dir.mkdir(parents=True, exist_ok=True)
        sftp = self._sftp()
        try:
            entries = self._list_remote_files(sftp, remote_expanded)
            total = sum(size for _, _, size in entries) or 1
            transferred_total = 0

            for remote_path, rel, size in entries:
                local_path = local_dir / rel.replace("/", os.sep)
                local_path.parent.mkdir(parents=True, exist_ok=True)
                file_base = transferred_total

                def _cb(
                    sent: int,
                    _total: int,
                    *,
                    _base: int = file_base,
                    _rel: str = rel,
                ) -> None:
                    if not on_progress:
                        return
                    pct = int((_base + sent) * 100 / total)
                    on_progress(min(99, pct), _rel)

                sftp.get(remote_path, str(local_path), callback=_cb)
                transferred_total += size
                if on_progress:
                    pct = int(transferred_total * 100 / total)
                    on_progress(min(99, pct), rel)

            if on_progress:
                on_progress(100, "Complete")
        finally:
            sftp.close()

    def upload_dir(
        self,
        local_dir: Path,
        remote_dir: str,
        on_progress: ProgressCallback | None = None,
    ) -> None:
        if not local_dir.is_dir():
            raise FileNotFoundError(f"Local directory not found: {local_dir}")
        remote_expanded = self.expand_path(remote_dir)
        sftp = self._sftp()
        try:
            entries = self._list_local_files(local_dir)
            total = sum(size for _, _, size in entries) or 1
            transferred_total = 0

            for local_path, rel, size in entries:
                remote_path = f"{remote_expanded}/{rel}"
                self._sftp_mkdir_p(sftp, str(PurePosixPath(remote_path).parent))
                file_base = transferred_total

                def _cb(
                    sent: int,
                    _total: int,
                    *,
                    _base: int = file_base,
                    _rel: str = rel,
                ) -> None:
                    if not on_progress:
                        return
                    pct = int((_base + sent) * 100 / total)
                    on_progress(min(99, pct), _rel)

                sftp.put(str(local_path), remote_path, callback=_cb)
                transferred_total += size
                if on_progress:
                    pct = int(transferred_total * 100 / total)
                    on_progress(min(99, pct), rel)

            if on_progress:
                on_progress(100, "Complete")
        finally:
            sftp.close()

    BACKUP_COMPONENTS = ("database.sql.gz", "moodlecode.tar.gz", "moodledata.tar.gz")

    def list_backup_dirs(self, storage_path: str) -> list[dict]:
        expanded = self.expand_path(storage_path)
        size_expr = (
            'sz=0; '
            '[ -f "$d/database.sql.gz" ] && sz=$((sz + $(stat -c%s "$d/database.sql.gz" 2>/dev/null || echo 0))); '
            '[ -f "$d/moodlecode.tar.gz" ] && sz=$((sz + $(stat -c%s "$d/moodlecode.tar.gz" 2>/dev/null || echo 0))); '
            '[ -f "$d/moodledata.tar.gz" ] && sz=$((sz + $(stat -c%s "$d/moodledata.tar.gz" 2>/dev/null || echo 0))); '
        )
        cmd = (
            f'for d in "{expanded}"/*/; do '
            f'[ -d "$d" ] || continue; '
            f'b=$(basename "$d"); '
            f'case "$b" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_*) '
            f'{size_expr} '
            f'err=0; [ -f "$d/backup.error.log" ] && err=1; '
            f'echo "$b|$sz|$err"; '
            f';; esac; done | sort -r'
        )
        out, _, _ = self.exec(cmd)
        result = []
        for line in out.strip().splitlines():
            parts = line.split("|")
            if len(parts) >= 3:
                result.append({
                    "name": parts[0],
                    "size": int(parts[1] or 0),
                    "has_error": parts[2] == "1",
                })
        return result

    def delete_remote_backup(self, storage_path: str, name: str) -> None:
        expanded = self.expand_path(f"{storage_path.rstrip('/')}/{name}")
        _, err, code = self.exec(f'rm -rf "{expanded}"')
        if code != 0:
            raise RuntimeError(err or f"Failed to delete {expanded}")

    @staticmethod
    def backup_dir_size(path: Path) -> int:
        total = 0
        for name in SSHClient.BACKUP_COMPONENTS:
            component = path / name
            if component.is_file():
                total += component.stat().st_size
        return total

    @staticmethod
    def delete_local_backup(archive_path: Path, name: str) -> None:
        target = archive_path / name
        if not target.is_dir():
            raise FileNotFoundError(f"Backup not found: {target}")
        shutil.rmtree(target)

    def write_remote_env(
        self,
        remote_bin: str,
        location: str,
        storage: str,
    ) -> None:
        expanded = self.expand_path(remote_bin)
        location = location.strip().replace("\r", "")
        storage = storage.strip().replace("\r", "")
        content = (
            f"BACKUPER_LOCATION={location}\n"
            f"BACKUPER_STORAGE_PATH={storage}\n"
        )
        tmp = Path(os.environ.get("TEMP", "/tmp")) / "moodle-backup.env"
        tmp.write_text(content, encoding="utf-8", newline="\n")
        self.upload_file(tmp, f"{expanded}/moodle-backup.env")
        self.exec(f'chmod 600 "{expanded}/moodle-backup.env" && sed -i "s/\\r$//" "{expanded}/moodle-backup.env"')
        tmp.unlink(missing_ok=True)

    def deploy_scripts(self, project_root: Path, remote_bin: str) -> None:
        expanded = self.expand_path(remote_bin)
        self.mkdir_p(expanded)
        self.mkdir_p(f"{expanded}/lib")

        remote_src = project_root / "remote"
        restore_src = project_root / "restore"

        if not (remote_src / "moodle-backup.sh").is_file():
            raise FileNotFoundError(f"Backup script not found: {remote_src / 'moodle-backup.sh'}")

        for name in ("moodle-backup.sh", "setup-moodledata-acl.sh"):
            script = remote_src / name
            if script.is_file():
                self.upload_file(script, f"{expanded}/{name}")

        lib_dir = remote_src / "lib"
        for sh in sorted(lib_dir.glob("*.sh")):
            self.upload_file(sh, f"{expanded}/lib/{sh.name}")
        for php in sorted(lib_dir.glob("*.php")):
            self.upload_file(php, f"{expanded}/lib/{php.name}")

        self.upload_file(restore_src / "moodle-restore.sh", f"{expanded}/moodle-restore.sh")
        self.upload_file(restore_src / "RESTORE.md", f"{expanded}/RESTORE.md")

        _, err, code = self.exec(
            f'chmod +x "{expanded}/moodle-backup.sh" '
            f'"{expanded}/moodle-restore.sh" '
            f'"{expanded}/setup-moodledata-acl.sh" '
            f'"{expanded}/lib/run_quiz_php.sh" '
            f'"{expanded}/lib/"*.sh && '
            f'sed -i "s/\\r$//" "{expanded}"/*.sh "{expanded}/lib/"*.sh "{expanded}/lib/"*.php 2>/dev/null; true'
        )
        if code != 0:
            raise RuntimeError(f"chmod failed: {err}")

    def list_quiz_attempts(self, remote_bin: str, moodle_root: str) -> dict:
        """Return open quiz attempts JSON from quiz_backup.php on the host."""
        import json
        import re

        expanded = self.expand_path(remote_bin)
        runner = f"{expanded}/lib/run_quiz_php.sh"
        cmd = f'bash "{runner}" "{moodle_root}" list'
        out, err, code = self.exec(cmd)
        if code != 0:
            raise RuntimeError(err or out or "quiz_backup.php list failed")
        match = re.search(r"\{.*\}", out, re.DOTALL)
        if not match:
            raise RuntimeError(f"No JSON in quiz list output: {out[:300]}")
        try:
            return json.loads(match.group(0))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Invalid JSON from quiz_backup.php: {exc}") from exc

    def send_backup_control(self, backup_dir: str, action: str) -> None:
        if action not in ("force", "cancel"):
            raise ValueError("action must be force or cancel")
        _, err, code = self.exec(f'printf "%s" "{action}" > "{backup_dir}/control"')
        if code != 0:
            raise RuntimeError(err or f"Failed to send backup control: {action}")

    @staticmethod
    def list_local_backups(archive_path: Path) -> list[dict]:
        result = []
        if not archive_path.exists():
            return result
        for entry in sorted(archive_path.iterdir(), reverse=True):
            if not entry.is_dir():
                continue
            name = entry.name
            if not is_backup_dir_name(name):
                continue
            size = SSHClient.backup_dir_size(entry)
            has_error = (entry / "backup.error.log").exists()
            result.append({"name": name, "size": size, "has_error": has_error})
        return result

    @staticmethod
    def format_size(size: int) -> str:
        for unit in ("B", "KB", "MB", "GB", "TB"):
            if size < 1024:
                return f"{size:.1f} {unit}" if unit != "B" else f"{size} B"
            size /= 1024
        return f"{size:.1f} PB"

    def install_authorized_key(self, public_key_line: str) -> None:
        import base64

        self.connect(force_password=True)
        payload = base64.b64encode(public_key_line.encode("utf-8")).decode("ascii")
        cmd = (
            "bash -lc "
            f"'set -e; pub=$(printf %s {payload} | base64 -d); "
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh; "
            "auth=~/.ssh/authorized_keys; touch \"$auth\" && chmod 600 \"$auth\"; "
            "grep -qxF \"$pub\" \"$auth\" 2>/dev/null || echo \"$pub\" >> \"$auth\"'"
        )
        out, err, code = self.exec(cmd)
        if code != 0:
            raise RuntimeError(err.strip() or out.strip() or "Failed to install public key")

    def remove_authorized_key(self, public_key_line: str) -> None:
        import base64

        self.connect(force_password=True)
        payload = base64.b64encode(public_key_line.encode("utf-8")).decode("ascii")
        cmd = (
            "bash -lc "
            f"'set -e; pub=$(printf %s {payload} | base64 -d); "
            "auth=~/.ssh/authorized_keys; "
            "if [ -f \"$auth\" ]; then "
            "tmp=$(mktemp); grep -vxF \"$pub\" \"$auth\" > \"$tmp\" || true; "
            "mv \"$tmp\" \"$auth\"; chmod 600 \"$auth\"; fi'"
        )
        out, err, code = self.exec(cmd)
        if code != 0:
            raise RuntimeError(err.strip() or out.strip() or "Failed to remove public key")
