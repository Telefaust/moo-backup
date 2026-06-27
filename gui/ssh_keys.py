"""SSH key pair storage and helpers (per connection profile)."""

from __future__ import annotations

import os
import shutil
import stat
from pathlib import Path

import paramiko
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519

from gui.profiles import GUI_DIR

KEYS_DIR = GUI_DIR / "keys"
PRIVATE_NAME = "id_ed25519"
PUBLIC_NAME = "id_ed25519.pub"


def profile_key_dir(profile_id: str) -> Path:
    return KEYS_DIR / profile_id


def private_key_path(profile_id: str) -> Path:
    return profile_key_dir(profile_id) / PRIVATE_NAME


def public_key_path(profile_id: str) -> Path:
    return profile_key_dir(profile_id) / PUBLIC_NAME


def has_key_pair(profile_id: str) -> bool:
    return private_key_path(profile_id).is_file() and public_key_path(profile_id).is_file()


def generate_key_pair(profile_id: str, comment: str = "") -> tuple[Path, Path]:
    key_dir = profile_key_dir(profile_id)
    key_dir.mkdir(parents=True, exist_ok=True)
    private_path = key_dir / PRIVATE_NAME
    public_path = key_dir / PUBLIC_NAME

    if private_path.exists() or public_path.exists():
        raise FileExistsError("Key pair already exists for this connection")

    private_key = ed25519.Ed25519PrivateKey.generate()
    private_bytes = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.OpenSSH,
        encryption_algorithm=serialization.NoEncryption(),
    )
    public_openssh = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.OpenSSH,
        format=serialization.PublicFormat.OpenSSH,
    ).decode("ascii").strip()
    label = comment.strip() or f"moobackup@{profile_id}"
    public_line = f"{public_openssh} {label}"

    private_path.write_bytes(private_bytes)
    public_path.write_text(public_line + "\n", encoding="utf-8")

    try:
        os.chmod(private_path, stat.S_IRUSR | stat.S_IWUSR)
        os.chmod(key_dir, stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    except OSError:
        pass

    return private_path, public_path


def delete_key_pair(profile_id: str) -> None:
    shutil.rmtree(profile_key_dir(profile_id), ignore_errors=True)


def rename_key_profile(old_id: str, new_id: str) -> None:
    if old_id == new_id:
        return
    old_dir = profile_key_dir(old_id)
    new_dir = profile_key_dir(new_id)
    if not old_dir.is_dir():
        return
    if new_dir.exists():
        raise FileExistsError(f"Key directory already exists for profile {new_id}")
    new_dir.parent.mkdir(parents=True, exist_ok=True)
    old_dir.rename(new_dir)


def read_public_key_line(profile_id: str) -> str:
    path = public_key_path(profile_id)
    if not path.is_file():
        raise FileNotFoundError("Public key not found")
    line = path.read_text(encoding="utf-8").strip()
    if not line:
        raise ValueError("Public key file is empty")
    return line


def load_private_key(path: Path) -> paramiko.PKey:
    errors: list[str] = []
    for key_class in (paramiko.Ed25519Key, paramiko.ECDSAKey, paramiko.RSAKey):
        try:
            return key_class.from_private_key_file(str(path))
        except Exception as exc:
            errors.append(str(exc))
    raise ValueError(f"Cannot load private key {path}: {'; '.join(errors)}")
