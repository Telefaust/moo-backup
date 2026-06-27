"""Dialog for managing connection profiles."""

from __future__ import annotations

import copy
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

from gui.profiles import ConnectionProfile, ProfileStore, make_profile_id
from gui.ssh_client import SSHClient
from gui.ssh_keys import (
    delete_key_pair,
    generate_key_pair,
    has_key_pair,
    read_public_key_line,
    rename_key_profile,
)


class SettingsDialog(tk.Toplevel):
    FIELD_ROWS = (
        ("Display name:", "name", False),
        ("SSH host:", "host", False),
        ("SSH login:", "login", False),
        ("SSH password:", "password", True),
        ("Site URL (FQDN):", "fqdn", False),
        ("Moodle path on host:", "location", False),
        ("Remote storage path:", "storage_path", False),
        ("Local archive (Windows):", "archive_path", False),
        ("Remote scripts dir:", "remote_bin", False),
    )

    def __init__(self, parent: tk.Misc, store: ProfileStore) -> None:
        super().__init__(parent)
        self.title("Connections")
        self.geometry("820x620")
        self.minsize(720, 560)

        self.store = copy.deepcopy(store)
        self.saved = False
        self._selected_id: str | None = None
        self._busy = False
        self.vars: dict[str, tk.StringVar] = {}

        body = ttk.Frame(self, padding=10)
        body.pack(fill=tk.BOTH, expand=True)

        left = ttk.LabelFrame(body, text="Connections", padding=6)
        left.pack(side=tk.LEFT, fill=tk.Y, padx=(0, 8))

        self.profile_list = tk.Listbox(left, width=24, exportselection=False)
        self.profile_list.pack(fill=tk.BOTH, expand=True)
        self.profile_list.bind("<<ListboxSelect>>", self._on_list_select)

        list_btns = ttk.Frame(left)
        list_btns.pack(fill=tk.X, pady=(6, 0))
        ttk.Button(list_btns, text="New", command=self._new_profile).pack(side=tk.LEFT, padx=2)
        ttk.Button(list_btns, text="Delete", command=self._delete_profile).pack(side=tk.LEFT, padx=2)

        right = ttk.LabelFrame(body, text="Settings", padding=8)
        right.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        right.columnconfigure(1, weight=1)

        for row, (label, key, secret) in enumerate(self.FIELD_ROWS):
            ttk.Label(right, text=label).grid(row=row, column=0, sticky="w", pady=4)
            var = tk.StringVar()
            show = "*" if secret else None
            if key == "archive_path":
                row_frame = ttk.Frame(right)
                row_frame.grid(row=row, column=1, sticky="ew", pady=4, padx=(8, 0))
                row_frame.columnconfigure(0, weight=1)
                entry = ttk.Entry(row_frame, textvariable=var, show=show)
                entry.grid(row=0, column=0, sticky="ew")
                ttk.Button(row_frame, text="Browse…", command=self._browse_archive).grid(
                    row=0, column=1, padx=(6, 0)
                )
            else:
                entry = ttk.Entry(right, textvariable=var, show=show)
                entry.grid(row=row, column=1, sticky="ew", pady=4, padx=(8, 0))
            self.vars[key] = var
            if key in ("host", "login", "password"):
                var.trace_add("write", self._on_form_changed)

        key_row = len(self.FIELD_ROWS)
        key_frame = ttk.LabelFrame(right, text="SSH key", padding=8)
        key_frame.grid(row=key_row, column=0, columnspan=2, sticky="ew", pady=(12, 0))
        key_frame.columnconfigure(0, weight=1)

        self.key_status_var = tk.StringVar(value="Key pair: not created")
        ttk.Label(key_frame, textvariable=self.key_status_var).grid(row=0, column=0, sticky="w")

        gen_row = ttk.Frame(key_frame)
        gen_row.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        self.btn_generate_key = ttk.Button(gen_row, text="Generate key pair", command=self._generate_key)
        self.btn_generate_key.pack(side=tk.LEFT, padx=(0, 4))
        self.btn_delete_key = ttk.Button(gen_row, text="Delete key pair", command=self._delete_key)
        self.btn_delete_key.pack(side=tk.LEFT)

        host_row = ttk.Frame(key_frame)
        host_row.grid(row=2, column=0, sticky="ew", pady=(8, 0))
        self.btn_copy_pubkey = ttk.Button(
            host_row, text="Copy public key", command=self._copy_public_key
        )
        self.btn_copy_pubkey.pack(side=tk.LEFT, padx=(0, 4))
        self.btn_activate_key = ttk.Button(
            host_row, text="Activate key on host", command=self._activate_key_on_host
        )
        self.btn_activate_key.pack(side=tk.LEFT, padx=(0, 4))
        self.btn_deactivate_key = ttk.Button(
            host_row, text="Deactivate key on host", command=self._deactivate_key_on_host
        )
        self.btn_deactivate_key.pack(side=tk.LEFT)

        self.key_hint_var = tk.StringVar()
        ttk.Label(
            key_frame,
            textvariable=self.key_hint_var,
            font=("", 8),
            wraplength=480,
        ).grid(row=3, column=0, sticky="w", pady=(8, 0))

        hint = ttk.Label(
            right,
            text="Profiles: gui/profiles.json | Keys: gui/keys/<profile-id>/\n"
            "Copy both to move connections to another PC.",
            font=("", 8),
            wraplength=420,
        )
        hint.grid(row=key_row + 1, column=0, columnspan=2, sticky="w", pady=(12, 0))

        bottom = ttk.Frame(self, padding=(10, 0, 10, 10))
        bottom.pack(fill=tk.X)
        ttk.Button(bottom, text="Set active", command=self._set_active).pack(side=tk.LEFT)
        ttk.Button(bottom, text="Save", command=self._save_current).pack(side=tk.RIGHT, padx=4)
        ttk.Button(bottom, text="Close", command=self._close).pack(side=tk.RIGHT)

        self._reload_list()
        if self.store.profiles:
            self.profile_list.selection_set(0)
            self._on_list_select()
        else:
            self._new_profile()

        self.protocol("WM_DELETE_WINDOW", self._close)
        self.update_idletasks()
        self.deiconify()
        self.lift()
        self.focus_force()
        self.transient(parent)
        self.grab_set()
        self.wait_window()

    def _on_form_changed(self, *_args: object) -> None:
        self._update_key_buttons()

    def _reload_list(self) -> None:
        self.profile_list.delete(0, tk.END)
        for profile in self.store.list_profiles():
            marker = " *" if profile.id == self.store.active_id else ""
            self.profile_list.insert(tk.END, f"{profile.name}{marker}")

    def _profile_at(self, index: int) -> ConnectionProfile | None:
        profiles = self.store.list_profiles()
        if 0 <= index < len(profiles):
            return profiles[index]
        return None

    def _on_list_select(self, _event: object | None = None) -> None:
        sel = self.profile_list.curselection()
        if not sel:
            return
        profile = self._profile_at(sel[0])
        if not profile:
            return
        self._selected_id = profile.id
        for key, var in self.vars.items():
            var.set(getattr(profile, key, ""))
        self._update_key_buttons()

    def _collect_form(self) -> ConnectionProfile | None:
        if not self._selected_id or self._selected_id not in self.store.profiles:
            return None
        profile = self.store.profiles[self._selected_id]
        for key, var in self.vars.items():
            value = var.get()
            if key != "password":
                value = value.strip()
            setattr(profile, key, value)
        return profile

    def _saved_profile(self) -> ConnectionProfile | None:
        if not self._selected_id:
            return None
        return self.store.profiles.get(self._selected_id)

    def _host_login_password_saved(self) -> bool:
        saved = self._saved_profile()
        if not saved:
            return False
        if not saved.host or not saved.login or not saved.password:
            return False
        return (
            self.vars["host"].get().strip() == saved.host
            and self.vars["login"].get().strip() == saved.login
            and self.vars["password"].get() == saved.password
        )

    def _update_key_buttons(self) -> None:
        profile_id = self._selected_id or ""
        key_exists = bool(profile_id) and has_key_pair(profile_id)
        saved_host = self._host_login_password_saved()

        if key_exists:
            self.key_status_var.set("Key pair: created (gui/keys/)")
        else:
            self.key_status_var.set("Key pair: not created")

        self.btn_generate_key.configure(state=tk.NORMAL if profile_id and not key_exists else tk.DISABLED)
        self.btn_delete_key.configure(state=tk.NORMAL if key_exists else tk.DISABLED)

        host_ops_state = tk.NORMAL if key_exists else tk.DISABLED
        self.btn_copy_pubkey.configure(state=host_ops_state)

        activate_state = tk.NORMAL if key_exists and saved_host and not self._busy else tk.DISABLED
        self.btn_activate_key.configure(state=activate_state)
        self.btn_deactivate_key.configure(state=activate_state)

        if not key_exists:
            self.key_hint_var.set("Generate a key pair for this connection.")
        elif not saved_host:
            self.key_hint_var.set("Save host, login and password before activating the key on the host.")
        else:
            self.key_hint_var.set(
                "Host operations use the saved password. Normal connection tries the key first, then password."
            )

    def _browse_archive(self) -> None:
        path = filedialog.askdirectory(title="Local archive folder")
        if path:
            self.vars["archive_path"].set(path)

    def _new_profile(self) -> None:
        profile = self.store.new_profile()
        self.store.upsert(profile)
        self._reload_list()
        idx = self.store.list_profiles().index(profile)
        self.profile_list.selection_clear(0, tk.END)
        self.profile_list.selection_set(idx)
        self.profile_list.event_generate("<<ListboxSelect>>")

    def _delete_profile(self) -> None:
        if not self._selected_id:
            return
        profile = self.store.profiles.get(self._selected_id)
        if not profile:
            return
        if not messagebox.askyesno(
            "Delete connection",
            f"Delete connection '{profile.name}'?",
            parent=self,
        ):
            return
        if has_key_pair(profile.id):
            if messagebox.askyesno(
                "Delete SSH key",
                "Also delete the local SSH key pair for this connection?",
                parent=self,
            ):
                delete_key_pair(profile.id)
        profile_id = profile.id
        self.store.delete(profile_id)
        self._selected_id = None
        self.store.save()
        self.saved = True
        self._reload_list()
        if self.store.profiles:
            self.profile_list.selection_set(0)
            self._on_list_select()
        else:
            for var in self.vars.values():
                var.set("")
            self._update_key_buttons()

    def _save_current(self) -> None:
        profile = self._collect_form()
        if not profile:
            messagebox.showerror("Error", "Select a connection first", parent=self)
            return
        missing = profile.validate()
        if missing:
            messagebox.showerror(
                "Validation",
                "Fill required fields:\n" + ", ".join(missing),
                parent=self,
            )
            return
        old_id = profile.id
        new_id = make_profile_id(profile.name, {pid for pid in self.store.profiles if pid != profile.id})
        if new_id != profile.id:
            try:
                rename_key_profile(old_id, new_id)
            except FileExistsError as exc:
                messagebox.showerror("SSH key", str(exc), parent=self)
                return
            profile.id = new_id
            self.store.profiles[new_id] = profile
            del self.store.profiles[old_id]
            if self.store.active_id == old_id:
                self.store.active_id = new_id
            self._selected_id = new_id
        self.store.upsert(profile)
        self.store.save()
        self.saved = True
        self._reload_list()
        profiles = self.store.list_profiles()
        for idx, item in enumerate(profiles):
            if item.id == profile.id:
                self.profile_list.selection_clear(0, tk.END)
                self.profile_list.selection_set(idx)
                break
        self._update_key_buttons()
        messagebox.showinfo("Saved", "Connection saved.", parent=self)

    def _set_active(self) -> None:
        profile = self._collect_form()
        if not profile:
            return
        missing = profile.validate()
        if missing:
            messagebox.showerror(
                "Validation",
                "Save a complete connection before activating it.",
                parent=self,
            )
            return
        self.store.set_active(profile.id)
        self.store.save()
        self.saved = True
        self._reload_list()

    def _generate_key(self) -> None:
        if not self._selected_id:
            return
        saved = self._saved_profile()
        if not saved or not saved.host:
            messagebox.showerror(
                "SSH key",
                "Save the connection (at least host and login) before generating a key.",
                parent=self,
            )
            return
        try:
            generate_key_pair(self._selected_id, comment=f"moobackup-{saved.login}@{saved.host}")
        except FileExistsError:
            messagebox.showerror("SSH key", "Key pair already exists.", parent=self)
            return
        except OSError as exc:
            messagebox.showerror("SSH key", str(exc), parent=self)
            return
        self._update_key_buttons()
        messagebox.showinfo("SSH key", "Key pair generated.", parent=self)

    def _delete_key(self) -> None:
        if not self._selected_id or not has_key_pair(self._selected_id):
            return
        if not messagebox.askyesno(
            "Delete SSH key",
            "Delete the local key pair for this connection?\n"
            "This does not remove the public key from remote hosts.",
            parent=self,
        ):
            return
        delete_key_pair(self._selected_id)
        self._update_key_buttons()

    def _copy_public_key(self) -> None:
        if not self._selected_id:
            return
        try:
            line = read_public_key_line(self._selected_id)
        except (OSError, ValueError) as exc:
            messagebox.showerror("SSH key", str(exc), parent=self)
            return
        self.clipboard_clear()
        self.clipboard_append(line)
        messagebox.showinfo("SSH key", "Public key copied to clipboard.", parent=self)

    def _run_host_key_op(self, action: str) -> None:
        saved = self._saved_profile()
        if not self._selected_id or not saved or not self._host_login_password_saved():
            messagebox.showerror(
                "SSH key",
                "Save host, login and password before changing the key on the host.",
                parent=self,
            )
            return
        try:
            public_line = read_public_key_line(self._selected_id)
        except (OSError, ValueError) as exc:
            messagebox.showerror("SSH key", str(exc), parent=self)
            return

        self._busy = True
        self._update_key_buttons()

        def task() -> None:
            try:
                client = SSHClient(saved.host, saved.login, saved.password)
                if action == "activate":
                    client.install_authorized_key(public_line)
                    msg = f"Public key installed on {saved.host} for user {saved.login}."
                else:
                    client.remove_authorized_key(public_line)
                    msg = f"Public key removed from {saved.host} for user {saved.login}."
                client.close()
                self.after(0, lambda: messagebox.showinfo("SSH key", msg, parent=self))
            except Exception as exc:
                self.after(0, lambda: messagebox.showerror("SSH key", str(exc), parent=self))
            finally:
                self.after(0, self._finish_host_key_op)

        threading.Thread(target=task, daemon=True).start()

    def _finish_host_key_op(self) -> None:
        self._busy = False
        self._update_key_buttons()

    def _activate_key_on_host(self) -> None:
        self._run_host_key_op("activate")

    def _deactivate_key_on_host(self) -> None:
        self._run_host_key_op("deactivate")

    def _close(self) -> None:
        self.destroy()
