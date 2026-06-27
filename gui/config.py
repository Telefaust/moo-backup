"""Load connection configuration from gui/profiles.json."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from gui.paths import app_root
from gui.profiles import ConnectionProfile, ProfileStore
from gui.ssh_keys import has_key_pair, private_key_path

PROJECT_ROOT = app_root()


@dataclass
class BackuperConfig:
    login: str
    password: str
    host: str
    fqdn: str
    location: str
    storage_path: str
    archive_path: Path
    remote_bin: str = "~/moobackup/bin"
    profile_id: str = ""
    profile_name: str = ""

    @property
    def ssh_private_key(self) -> Path | None:
        if not self.profile_id or not has_key_pair(self.profile_id):
            return None
        return private_key_path(self.profile_id)

    @classmethod
    def from_profile(cls, profile: ConnectionProfile) -> BackuperConfig:
        archive = Path(profile.archive_path)
        archive.mkdir(parents=True, exist_ok=True)
        return cls(
            login=profile.login,
            password=profile.password,
            host=profile.host,
            fqdn=profile.fqdn,
            location=profile.location,
            storage_path=profile.storage_path,
            archive_path=archive,
            remote_bin=profile.remote_bin,
            profile_id=profile.id,
            profile_name=profile.name,
        )

    @classmethod
    def load(cls, store: ProfileStore | None = None) -> BackuperConfig:
        profile_store = store or ProfileStore.load()
        profile = profile_store.get_active_profile()
        if not profile:
            raise ValueError(
                "No connection profiles configured. "
                "Open Connections and create one, or copy gui/profiles.json."
            )
        missing = profile.validate()
        if missing:
            raise ValueError(
                f"Active profile '{profile.name}' is incomplete. "
                f"Missing: {', '.join(missing)}"
            )
        return cls.from_profile(profile)

    def remote_backup_script(self) -> str:
        return f"{self.remote_bin}/moodle-backup.sh"

    def remote_restore_script(self) -> str:
        return f"{self.remote_bin}/moodle-restore.sh"
