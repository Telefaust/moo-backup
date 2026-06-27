"""Connection profiles stored in gui/profiles.json (portable, multi-host)."""

from __future__ import annotations

import json
import re
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path

from gui.paths import gui_dir

GUI_DIR = gui_dir()
PROFILES_FILE = GUI_DIR / "profiles.json"

PROFILE_VERSION = 1


@dataclass
class ConnectionProfile:
    id: str
    name: str
    host: str
    login: str
    password: str
    fqdn: str = ""
    location: str = "/var/www/moodle"
    storage_path: str = "/home/user/moobackup"
    archive_path: str = ""
    remote_bin: str = "~/moobackup/bin"

    def validate(self) -> list[str]:
        missing: list[str] = []
        for key in ("name", "host", "login", "password", "location", "storage_path", "archive_path"):
            if not getattr(self, key, "").strip():
                missing.append(key)
        return missing


@dataclass
class ProfileStore:
    active_id: str = ""
    profiles: dict[str, ConnectionProfile] = field(default_factory=dict)

    @classmethod
    def load(cls) -> ProfileStore:
        if PROFILES_FILE.exists():
            return cls._load_file(PROFILES_FILE)
        return cls()

    @classmethod
    def _load_file(cls, path: Path) -> ProfileStore:
        raw = json.loads(path.read_text(encoding="utf-8"))
        active_id = str(raw.get("active_id", "") or "")
        profiles: dict[str, ConnectionProfile] = {}
        for pid, item in (raw.get("profiles") or {}).items():
            profiles[str(pid)] = ConnectionProfile(
                id=str(pid),
                name=item.get("name", pid),
                host=item.get("host", ""),
                login=item.get("login", ""),
                password=item.get("password", ""),
                fqdn=item.get("fqdn", ""),
                location=item.get("location", ""),
                storage_path=item.get("storage_path", ""),
                archive_path=item.get("archive_path", ""),
                remote_bin=item.get("remote_bin", "~/moobackup/bin"),
            )
        if active_id and active_id not in profiles and profiles:
            active_id = next(iter(profiles))
        return cls(active_id=active_id, profiles=profiles)

    def save(self) -> None:
        PROFILES_FILE.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "version": PROFILE_VERSION,
            "active_id": self.active_id,
            "profiles": {
                pid: {k: v for k, v in asdict(profile).items() if k != "id"}
                for pid, profile in self.profiles.items()
            },
        }
        PROFILES_FILE.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )

    def list_profiles(self) -> list[ConnectionProfile]:
        return sorted(self.profiles.values(), key=lambda p: p.name.lower())

    def get_active_profile(self) -> ConnectionProfile | None:
        if not self.profiles:
            return None
        if self.active_id in self.profiles:
            return self.profiles[self.active_id]
        self.active_id = next(iter(self.profiles))
        return self.profiles[self.active_id]

    def set_active(self, profile_id: str) -> None:
        if profile_id not in self.profiles:
            raise KeyError(f"Unknown profile: {profile_id}")
        self.active_id = profile_id

    def upsert(self, profile: ConnectionProfile) -> None:
        self.profiles[profile.id] = profile
        if not self.active_id:
            self.active_id = profile.id

    def delete(self, profile_id: str) -> None:
        if profile_id not in self.profiles:
            return
        del self.profiles[profile_id]
        if self.active_id == profile_id:
            self.active_id = next(iter(self.profiles), "")

    def new_profile(self, name: str = "New connection") -> ConnectionProfile:
        profile_id = make_profile_id(name, set(self.profiles))
        return ConnectionProfile(
            id=profile_id,
            name=name,
            host="",
            login="",
            password="",
            archive_path=str(Path.home() / "Moo-backups"),
        )


def make_profile_id(name: str, existing: set[str]) -> str:
    base = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    if not base:
        base = "profile"
    candidate = base
    suffix = 2
    while candidate in existing:
        candidate = f"{base}-{suffix}"
        suffix += 1
    return candidate


def new_unique_profile_id(existing: set[str]) -> str:
    while True:
        candidate = f"profile-{uuid.uuid4().hex[:8]}"
        if candidate not in existing:
            return candidate
