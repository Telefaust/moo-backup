"""Tkinter GUI for Moodle backup management."""

from __future__ import annotations

import json
import sys
import tkinter as tk
from tkinter import messagebox, scrolledtext, ttk

from gui.config import BackuperConfig, PROJECT_ROOT
from gui.profiles import ProfileStore
from gui.ssh_client import SSHClient
from gui.ui.settings_dialog import SettingsDialog


class RestoreDialog(tk.Toplevel):
    def __init__(self, parent: tk.Misc, default_webroot: str, default_dataroot: str) -> None:
        super().__init__(parent)
        self.title("Restore — credentials")
        self.resizable(False, False)
        self.result: dict | None = None

        frame = ttk.Frame(self, padding=12)
        frame.grid(row=0, column=0, sticky="nsew")

        rows = [
            ("Restore user (SSH login):", "login", ""),
            ("Password:", "password", ""),
            ("Webroot:", "webroot", default_webroot),
            ("Moodledata:", "dataroot", default_dataroot),
        ]
        self.vars: dict[str, tk.StringVar] = {}
        for i, (label, key, default) in enumerate(rows):
            ttk.Label(frame, text=label).grid(row=i, column=0, sticky="w", pady=4)
            var = tk.StringVar(value=default)
            show = "*" if key == "password" else None
            entry = ttk.Entry(frame, textvariable=var, width=40, show=show)
            entry.grid(row=i, column=1, sticky="ew", pady=4, padx=(8, 0))
            self.vars[key] = var

        btn_frame = ttk.Frame(frame)
        btn_frame.grid(row=len(rows), column=0, columnspan=2, pady=(12, 0))
        ttk.Button(btn_frame, text="Cancel", command=self.destroy).pack(side=tk.LEFT, padx=4)
        ttk.Button(btn_frame, text="Run restore", command=self._ok).pack(side=tk.LEFT, padx=4)

        self.transient(parent)
        self.grab_set()
        self.wait_window()

    def _ok(self) -> None:
        login = self.vars["login"].get().strip()
        password = self.vars["password"].get()
        if not login or not password:
            messagebox.showerror("Error", "Login and password are required", parent=self)
            return
        self.result = {k: v.get().strip() for k, v in self.vars.items()}
        self.destroy()


class BackuperApp(tk.Tk):
    def __init__(self, config: BackuperConfig, store: ProfileStore) -> None:
        super().__init__()
        self.config_data = config
        self.store = store
        self.ssh: SSHClient | None = None
        self._busy = False
        self._last_progress_pct = -1
        self._profile_ids: list[str] = []
        self._switching_profile = False
        self._backup_dir: str | None = None
        self._quiz_poll_after: str | None = None
        self._backup_waiting_quiz = False

        self.title("Moo-backup — Moodle Backup Manager")
        self.geometry("960x680")
        self.minsize(800, 560)

        self._build_ui()
        self._refresh_local()
        self.after(200, self._auto_connect)

    def _build_ui(self) -> None:
        self.status_var = tk.StringVar(value="Disconnected")
        self.info_var = tk.StringVar()
        status_bar = ttk.Frame(self, padding=(8, 4))
        ttk.Label(status_bar, textvariable=self.info_var, font=("", 8)).pack(
            side=tk.LEFT, fill=tk.X, expand=True
        )
        ttk.Label(status_bar, textvariable=self.status_var, font=("", 9)).pack(side=tk.RIGHT)
        status_bar.pack(side=tk.BOTTOM, fill=tk.X)
        ttk.Separator(self, orient=tk.HORIZONTAL).pack(side=tk.BOTTOM, fill=tk.X)

        conn_bar = ttk.Frame(self, padding=8)
        conn_bar.pack(fill=tk.X)

        ttk.Label(conn_bar, text="Connection:").pack(side=tk.LEFT, padx=(0, 4))
        self.profile_var = tk.StringVar()
        self.profile_combo = ttk.Combobox(
            conn_bar, textvariable=self.profile_var, state="readonly", width=28
        )
        self.profile_combo.pack(side=tk.LEFT, padx=(0, 4))
        self.profile_combo.bind("<<ComboboxSelected>>", self._on_profile_selected)

        self.conn_ok_label = tk.Label(
            conn_bar, text="✓", fg="#1a8f1a", font=("Segoe UI Symbol", 12, "bold")
        )
        # packed when connected

        ttk.Button(conn_bar, text="Connections…", command=self._open_settings).pack(
            side=tk.LEFT, padx=(4, 4)
        )
        ttk.Button(conn_bar, text="Connect", command=self._connect).pack(side=tk.LEFT)

        self._reload_profile_combo()

        host_info_bar = ttk.Frame(self, padding=(8, 0))
        host_info_bar.pack(fill=tk.X)
        self.host_info_var = tk.StringVar(value="")
        ttk.Label(
            host_info_bar,
            textvariable=self.host_info_var,
            font=("", 9),
            wraplength=900,
        ).pack(anchor=tk.W)

        backup_bar = ttk.Frame(self, padding=(8, 4))
        backup_bar.pack(fill=tk.X)
        self.full_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(backup_bar, text="Full moodledata (--full)", variable=self.full_var).pack(
            side=tk.LEFT
        )
        self.simulate_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            backup_bar,
            text="Simulate backup (--simulate)",
            variable=self.simulate_var,
            command=self._update_simulate_controls,
        ).pack(side=tk.LEFT, padx=(8, 0))
        ttk.Label(backup_bar, text="Delay (s):").pack(side=tk.LEFT, padx=(8, 0))
        self.simulate_seconds_var = tk.StringVar(value="5")
        self.simulate_seconds_spin = ttk.Spinbox(
            backup_bar,
            from_=1,
            to=86400,
            width=6,
            textvariable=self.simulate_seconds_var,
            state=tk.DISABLED,
        )
        self.simulate_seconds_spin.pack(side=tk.LEFT)
        ttk.Button(backup_bar, text="Run Backup", command=self._run_backup).pack(side=tk.LEFT, padx=8)
        self.force_backup_btn = ttk.Button(
            backup_bar, text="Force backup", command=self._force_backup, state=tk.DISABLED
        )
        self.force_backup_btn.pack(side=tk.LEFT, padx=4)
        self.cancel_backup_btn = ttk.Button(
            backup_bar, text="Cancel backup", command=self._cancel_backup, state=tk.DISABLED
        )
        self.cancel_backup_btn.pack(side=tk.LEFT, padx=4)
        ttk.Button(backup_bar, text="Restore", command=self._run_restore).pack(side=tk.LEFT, padx=4)
        ttk.Button(backup_bar, text="Deploy scripts", command=self._deploy).pack(side=tk.LEFT, padx=4)

        lists = ttk.Frame(self, padding=8)
        lists.pack(fill=tk.BOTH, expand=True)

        remote_frame = ttk.LabelFrame(lists, text="Remote backups (host)")
        remote_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 4))
        self.remote_list = tk.Listbox(remote_frame, exportselection=False)
        self.remote_list.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        rf_btns = ttk.Frame(remote_frame)
        rf_btns.pack(fill=tk.X, padx=4, pady=(0, 4))
        ttk.Button(rf_btns, text="Refresh", command=self._refresh_remote).pack(side=tk.LEFT, padx=2)
        ttk.Button(rf_btns, text="Download", command=self._download).pack(side=tk.LEFT, padx=2)
        ttk.Button(rf_btns, text="Delete", command=self._delete_remote).pack(side=tk.LEFT, padx=2)
        ttk.Button(rf_btns, text="View log", command=lambda: self._view_log(remote=True)).pack(side=tk.LEFT, padx=2)

        local_frame = ttk.LabelFrame(lists, text="Local backups (Windows)")
        local_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(4, 0))
        self.local_list = tk.Listbox(local_frame, exportselection=False)
        self.local_list.pack(fill=tk.BOTH, expand=True, padx=4, pady=4)
        lf_btns = ttk.Frame(local_frame)
        lf_btns.pack(fill=tk.X, padx=4, pady=(0, 4))
        ttk.Button(lf_btns, text="Refresh", command=self._refresh_local).pack(side=tk.LEFT, padx=2)
        ttk.Button(lf_btns, text="Upload", command=self._upload).pack(side=tk.LEFT, padx=2)
        ttk.Button(lf_btns, text="Delete", command=self._delete_local).pack(side=tk.LEFT, padx=2)
        ttk.Button(lf_btns, text="View log", command=lambda: self._view_log(remote=False)).pack(side=tk.LEFT, padx=2)

        progress_frame = ttk.Frame(self, padding=(8, 0))
        progress_frame.pack(fill=tk.X, padx=8)
        self.progress_stage_var = tk.StringVar(value="")
        ttk.Label(progress_frame, textvariable=self.progress_stage_var).pack(anchor=tk.W)
        self.progress_var = tk.DoubleVar(value=0.0)
        self.progress_bar = ttk.Progressbar(
            progress_frame, variable=self.progress_var, maximum=100, mode="determinate"
        )
        self.progress_bar.pack(fill=tk.X, pady=(2, 0))

        quiz_frame = ttk.LabelFrame(self, text="Open quiz attempts (live)", padding=4)
        quiz_frame.pack(fill=tk.X, padx=8, pady=(4, 0))
        cols = ("user", "quiz", "course", "state", "left")
        self.quiz_tree = ttk.Treeview(quiz_frame, columns=cols, show="headings", height=4)
        self.quiz_tree.heading("user", text="User")
        self.quiz_tree.heading("quiz", text="Quiz")
        self.quiz_tree.heading("course", text="Course")
        self.quiz_tree.heading("state", text="State")
        self.quiz_tree.heading("left", text="Time left")
        self.quiz_tree.column("user", width=160, stretch=True)
        self.quiz_tree.column("quiz", width=180, stretch=True)
        self.quiz_tree.column("course", width=100, stretch=False)
        self.quiz_tree.column("state", width=80, stretch=False)
        self.quiz_tree.column("left", width=80, stretch=False)
        self.quiz_tree.pack(fill=tk.X, expand=False)

        log_frame = ttk.LabelFrame(self, text="Log", padding=4)
        log_frame.pack(fill=tk.BOTH, expand=False, padx=8, pady=(8, 4))
        self.log_text = scrolledtext.ScrolledText(log_frame, height=8, state=tk.DISABLED)
        self.log_text.pack(fill=tk.BOTH, expand=True)

        self._update_info_line()
        self._set_connection_disconnected()

    def _update_info_line(self) -> None:
        self.info_var.set(
            f"Profile: {self.config_data.profile_name} | Host: {self.config_data.host} | "
            f"Storage: {self.config_data.storage_path} | Local: {self.config_data.archive_path}"
        )

    @staticmethod
    def _parse_connection_info(raw: str) -> tuple[str, str]:
        lines = [line.strip() for line in raw.splitlines() if line.strip()]
        if not lines:
            return "", ""
        if lines[0].lower() == "ok" and len(lines) > 1:
            return lines[1], lines[1]
        if lines[0].lower() == "ok":
            return "", ""
        return raw.strip(), raw.strip()

    def _set_connection_connected(self, auth: str, host_info: str) -> None:
        status = "Connected ok"
        if auth and auth != "unknown":
            status = f"Connected ok ({auth})"
        self.status_var.set(status)
        self.host_info_var.set(host_info)
        self.conn_ok_label.pack(side=tk.LEFT, padx=(0, 4), after=self.profile_combo)

    def _set_connection_disconnected(self) -> None:
        self.status_var.set("Disconnected")
        self.host_info_var.set("")
        if self.conn_ok_label.winfo_ismapped():
            self.conn_ok_label.pack_forget()

    def _reload_profile_combo(self) -> None:
        profiles = self.store.list_profiles()
        self._profile_ids = [p.id for p in profiles]
        names = [p.name for p in profiles]
        self.profile_combo["values"] = names
        if self.config_data.profile_id in self._profile_ids:
            idx = self._profile_ids.index(self.config_data.profile_id)
        elif self.store.active_id in self._profile_ids:
            idx = self._profile_ids.index(self.store.active_id)
        else:
            idx = 0 if names else -1
        if idx >= 0:
            self._switching_profile = True
            self.profile_combo.current(idx)
            self.profile_var.set(names[idx])
            self._switching_profile = False

    def _open_settings(self) -> None:
        if self._busy:
            messagebox.showwarning("Busy", "Wait for the current operation to finish.")
            return
        dialog = SettingsDialog(self, self.store)
        if not dialog.saved:
            return
        self.store = ProfileStore.load()
        profile = self.store.get_active_profile()
        if not profile:
            return
        try:
            config = BackuperConfig.from_profile(profile)
        except ValueError as exc:
            messagebox.showerror("Configuration", str(exc))
            return
        self._apply_profile(config, reconnect=True)

    def _on_profile_selected(self, _event: object | None = None) -> None:
        if self._switching_profile or self._busy:
            return
        idx = self.profile_combo.current()
        if idx < 0 or idx >= len(self._profile_ids):
            return
        profile_id = self._profile_ids[idx]
        if profile_id == self.store.active_id:
            return
        profile = self.store.profiles.get(profile_id)
        if not profile:
            return
        missing = profile.validate()
        if missing:
            messagebox.showerror(
                "Incomplete profile",
                f"Connection '{profile.name}' is missing: {', '.join(missing)}.\n"
                "Open Connections to edit it.",
            )
            self._reload_profile_combo()
            return
        self.store.set_active(profile_id)
        self.store.save()
        self._apply_profile(BackuperConfig.from_profile(profile), reconnect=True)

    def _apply_profile(self, config: BackuperConfig, reconnect: bool) -> None:
        if self.ssh:
            self.ssh.close()
            self.ssh = None
        self.config_data = config
        self._reload_profile_combo()
        self._update_info_line()
        self._set_connection_disconnected()
        self.remote_list.delete(0, tk.END)
        self._refresh_local()
        self.log(f"Switched to connection: {config.profile_name} ({config.host})")
        if reconnect:
            self.after(100, self._connect)

    def log(self, message: str) -> None:
        if "@PROGRESS" in message:
            idx = message.find("@PROGRESS")
            self._handle_progress(message[idx:])
            return
        if "@BACKUP_DIR" in message:
            parts = message.split("@BACKUP_DIR", 1)[-1].strip().split()
            if parts:
                self._backup_dir = parts[0]
            return
        if "@QUIZ_ATTEMPTS" in message:
            payload = message.split("@QUIZ_ATTEMPTS", 1)[-1].strip()
            self._apply_quiz_attempts_json(payload)
            return
        if "@BACKUP_WAIT" in message:
            self._handle_backup_wait(message.split("@BACKUP_WAIT", 1)[-1].strip())
            return

        def _append() -> None:
            self.log_text.configure(state=tk.NORMAL)
            self.log_text.insert(tk.END, message + "\n")
            self.log_text.see(tk.END)
            self.log_text.configure(state=tk.DISABLED)

        self.after(0, _append)

    def _handle_progress(self, message: str) -> None:
        # Format: @PROGRESS step percent [detail...]
        payload = message.split("@PROGRESS", 1)[-1].strip()
        parts = payload.split(maxsplit=2)
        if len(parts) < 2:
            return
        step = parts[0]
        try:
            pct = float(parts[1])
        except ValueError:
            return
        detail = parts[2] if len(parts) > 2 else ""
        labels = {
            "database": "Database dump",
            "moodlecode": "Moodle code",
            "moodledata": "Moodledata",
            "quizwait": "Waiting for quiz attempts",
            "complete": "Complete",
            "download": "Download",
            "upload": "Upload",
        }
        label = labels.get(step, step)

        def _update() -> None:
            self.progress_stage_var.set(f"{label}: {pct:.0f}% {detail}".strip())
            self.progress_var.set(max(0.0, min(100.0, pct)))

        self.after(0, _update)

    def _update_progress(self, step: str, pct: float, detail: str = "") -> None:
        self._handle_progress(f"@PROGRESS {step} {pct} {detail}".strip())

    def _reset_progress(self) -> None:
        self.progress_var.set(0.0)
        self.progress_stage_var.set("")
        self._last_progress_pct = -1
        self._clear_quiz_tree()

    @staticmethod
    def _format_seconds_left(seconds: int | None, deadline_known: bool) -> str:
        if not deadline_known or seconds is None:
            return "—"
        if seconds <= 0:
            return "0:00"
        return f"{seconds // 60}:{seconds % 60:02d}"

    def _clear_quiz_tree(self) -> None:
        for item in self.quiz_tree.get_children():
            self.quiz_tree.delete(item)

    def _apply_quiz_attempts_json(self, payload: str) -> None:
        try:
            data = json.loads(payload)
        except json.JSONDecodeError:
            return

        def _update() -> None:
            self._clear_quiz_tree()
            for att in data.get("attempts", []):
                left = self._format_seconds_left(
                    att.get("seconds_left"),
                    bool(att.get("deadline_known")),
                )
                self.quiz_tree.insert(
                    "",
                    tk.END,
                    values=(
                        att.get("user_name", ""),
                        att.get("quiz_name", ""),
                        att.get("course_shortname", ""),
                        att.get("state", ""),
                        left,
                    ),
                )

        self.after(0, _update)

    def _handle_backup_wait(self, payload: str) -> None:
        parts = payload.split()
        if not parts:
            return
        phase = parts[0]
        waiting = phase in ("start", "poll")
        self._backup_waiting_quiz = waiting
        self.after(0, lambda: self._set_backup_control_buttons(waiting))
        if waiting:
            self.after(0, self._schedule_quiz_poll)

    def _set_backup_control_buttons(self, enabled: bool) -> None:
        state = tk.NORMAL if enabled and self._busy else tk.DISABLED
        self.force_backup_btn.configure(state=state)
        self.cancel_backup_btn.configure(state=state)

    def _stop_quiz_poll(self) -> None:
        if self._quiz_poll_after is not None:
            try:
                self.after_cancel(self._quiz_poll_after)
            except tk.TclError:
                pass
            self._quiz_poll_after = None

    def _schedule_quiz_poll(self) -> None:
        self._stop_quiz_poll()
        if not self._busy or not self._backup_waiting_quiz:
            return
        self._quiz_poll_after = self.after(30_000, self._poll_quiz_sessions)

    def _poll_quiz_sessions(self) -> None:
        self._quiz_poll_after = None
        if not self._busy or not self.ssh or not self._backup_waiting_quiz:
            return
        try:
            data = self.ssh.list_quiz_attempts(
                self.config_data.remote_bin,
                self.config_data.location,
            )
            self._apply_quiz_attempts_json(json.dumps(data))
        except Exception as exc:
            self.log(f"Quiz poll error: {exc}")
        self._schedule_quiz_poll()

    def _force_backup(self) -> None:
        if not self._backup_dir or not self.ssh:
            return
        if not messagebox.askyesno(
            "Force backup",
            "Proceed with backup while quiz attempts may still be open?\n"
            "Active sessions will be interrupted by maintenance mode.",
            icon=messagebox.WARNING,
        ):
            return
        try:
            self.ssh.send_backup_control(self._backup_dir, "force")
            self.log("Sent force backup request to host")
            self._backup_waiting_quiz = False
            self._set_backup_control_buttons(False)
        except Exception as exc:
            messagebox.showerror("Force backup", str(exc))

    def _cancel_backup(self) -> None:
        if not self._backup_dir or not self.ssh:
            return
        if not messagebox.askyesno(
            "Cancel backup",
            "Cancel the running backup?\nThe backup-notice banner will be removed.",
            icon=messagebox.WARNING,
        ):
            return
        try:
            self.ssh.send_backup_control(self._backup_dir, "cancel")
            self.log("Sent cancel backup request to host")
        except Exception as exc:
            messagebox.showerror("Cancel backup", str(exc))

    def _confirm_delete(self, name: str, location: str) -> bool:
        return messagebox.askyesno(
            "Delete backup",
            f"Delete backup {name} on {location}?\n\nThis cannot be undone.",
            icon=messagebox.WARNING,
        )

    def _set_busy(self, busy: bool) -> None:
        self._busy = busy
        state = tk.DISABLED if busy else tk.NORMAL
        for w in self.winfo_children():
            try:
                for c in w.winfo_children():
                    if isinstance(c, (ttk.Button, ttk.Checkbutton)):
                        if c in (self.force_backup_btn, self.cancel_backup_btn):
                            continue
                        c.configure(state=state)
            except tk.TclError:
                pass
        if not busy:
            self._backup_dir = None
            self._backup_waiting_quiz = False
            self._stop_quiz_poll()
            self._set_backup_control_buttons(False)
        else:
            self._set_backup_control_buttons(self._backup_waiting_quiz)
        if not busy:
            self._update_simulate_controls()

    def _update_simulate_controls(self) -> None:
        if self._busy:
            return
        spin_state = tk.NORMAL if self.simulate_var.get() else tk.DISABLED
        self.simulate_seconds_spin.configure(state=spin_state)

    def _parse_simulate_seconds(self) -> int | None:
        raw = self.simulate_seconds_var.get().strip()
        try:
            secs = int(raw)
        except ValueError:
            return None
        if secs < 1:
            return None
        return secs

    def _auto_connect(self) -> None:
        try:
            self._connect()
        except Exception as exc:
            self.log(f"Auto-connect failed: {exc}")

    def _connect(self) -> None:
        try:
            if self.ssh:
                self.ssh.close()
                self.ssh = None
            self.ssh = SSHClient(
                self.config_data.host,
                self.config_data.login,
                self.config_data.password,
                private_key_path=self.config_data.ssh_private_key,
            )
            info = self.ssh.test_connection()
            auth = self.ssh.auth_method or "unknown"
            _, host_info = self._parse_connection_info(info)
            self._set_connection_connected(auth, host_info)
            self.log(f"Connected to {self.config_data.host} via {auth}")
            if host_info:
                self.log(host_info)
            self._refresh_remote()
            self._refresh_local()
        except Exception as exc:
            self._set_connection_disconnected()
            messagebox.showerror("Connection error", str(exc))

    def _require_ssh(self) -> SSHClient:
        if not self.ssh:
            raise RuntimeError("Not connected — click Connect first")
        return self.ssh

    def _deploy(self) -> None:
        if self._busy:
            return
        try:
            ssh = self._require_ssh()
            self.log("Deploying scripts...")
            ssh.deploy_scripts(PROJECT_ROOT, self.config_data.remote_bin)
            ssh.write_remote_env(
                self.config_data.remote_bin,
                self.config_data.location,
                self.config_data.storage_path,
            )
            ssh.mkdir_p(self.config_data.storage_path)
            self.log("Scripts deployed to ~/moobackup/bin")
            messagebox.showinfo("Deploy", "Scripts deployed successfully")
        except Exception as exc:
            messagebox.showerror("Deploy error", str(exc))
            self.log(f"Deploy error: {exc}")

    def _refresh_remote(self) -> None:
        self.remote_list.delete(0, tk.END)
        try:
            if not self.ssh:
                return
            backups = self.ssh.list_backup_dirs(self.config_data.storage_path)
            self._remote_backups = backups
            for b in backups:
                err = " [ERROR]" if b["has_error"] else ""
                size = SSHClient.format_size(b["size"])
                self.remote_list.insert(tk.END, f"{b['name']}  ({size}){err}")
        except Exception as exc:
            self.log(f"Remote list error: {exc}")

    def _refresh_local(self) -> None:
        self.local_list.delete(0, tk.END)
        backups = SSHClient.list_local_backups(self.config_data.archive_path)
        self._local_backups = backups
        for b in backups:
            err = " [ERROR]" if b["has_error"] else ""
            size = SSHClient.format_size(b["size"])
            self.local_list.insert(tk.END, f"{b['name']}  ({size}){err}")

    def _selected_remote_name(self) -> str | None:
        sel = self.remote_list.curselection()
        if not sel:
            return None
        text = self.remote_list.get(sel[0])
        return text.split()[0]

    def _selected_local_name(self) -> str | None:
        sel = self.local_list.curselection()
        if not sel:
            return None
        text = self.local_list.get(sel[0])
        return text.split()[0]

    def _run_backup(self) -> None:
        if self._busy:
            return
        try:
            ssh = self._require_ssh()
        except Exception as exc:
            messagebox.showerror("Error", str(exc))
            return

        full = " --full" if self.full_var.get() else ""
        simulate = ""
        if self.simulate_var.get():
            secs = self._parse_simulate_seconds()
            if secs is None:
                messagebox.showerror("Error", "Simulate delay must be a positive integer (seconds).")
                return
            simulate = f" --simulate --simulate-seconds {secs}"
        script = self.config_data.remote_backup_script()
        cmd = f'bash -lc \'{script}{full}{simulate}\''

        self._set_busy(True)
        self._backup_dir = None
        self._backup_waiting_quiz = False
        self._reset_progress()
        self._clear_quiz_tree()
        self.log(f"Starting backup: {cmd}")

        def on_done(code: int) -> None:
            self.after(0, lambda: self._on_backup_done(code))

        ssh.exec_stream(cmd, self.log, on_done)

    def _on_backup_done(self, code: int) -> None:
        self._stop_quiz_poll()
        self._set_busy(False)
        if code == 0:
            self.progress_var.set(100.0)
            self.progress_stage_var.set("Complete: 100%")
        self.log(f"Backup finished with exit code {code}")
        self._refresh_remote()
        if code == 5:
            messagebox.showinfo("Backup", "Backup cancelled.")
        elif code == 6:
            messagebox.showwarning("Backup", "Quiz preparation failed (exit 6). See log.")
        elif code != 0:
            messagebox.showwarning("Backup", f"Backup failed (exit {code}). See log.")

    def _run_restore(self) -> None:
        if self._busy:
            return
        name = self._selected_remote_name()
        if not name:
            messagebox.showinfo("Restore", "Select a remote backup first")
            return

        dlg = RestoreDialog(
            self,
            default_webroot=self.config_data.location,
            default_dataroot="",
        )
        if not dlg.result:
            return

        archive = f"{self.config_data.storage_path}/{name}"
        webroot = dlg.result["webroot"]
        dataroot = dlg.result["dataroot"]
        script = self.config_data.remote_restore_script()

        dataroot_arg = f' --dataroot "{dataroot}"' if dataroot else ""
        cmd = (
            f'bash -lc \'{script} --archive "{archive}" '
            f'--webroot "{webroot}"{dataroot_arg}\''
        )

        self._set_busy(True)
        self.log(f"Starting restore as {dlg.result['login']}...")

        restore_ssh = SSHClient(
            self.config_data.host,
            dlg.result["login"],
            dlg.result["password"],
        )

        def run() -> None:
            try:
                restore_ssh.connect()
                restore_ssh.exec_stream(
                    cmd,
                    self.log,
                    lambda code: self.after(0, lambda: self._on_restore_done(code)),
                )
            except Exception as exc:
                self.after(0, lambda: self._on_restore_error(str(exc)))

        import threading
        threading.Thread(target=run, daemon=True).start()

    def _on_restore_done(self, code: int) -> None:
        self._set_busy(False)
        self.log(f"Restore finished with exit code {code}")
        if code == 0:
            messagebox.showinfo("Restore", "Restore completed")
        else:
            messagebox.showwarning("Restore", f"Restore failed (exit {code})")

    def _on_restore_error(self, msg: str) -> None:
        self._set_busy(False)
        self.log(f"Restore error: {msg}")
        messagebox.showerror("Restore error", msg)

    def _download(self) -> None:
        if self._busy:
            return
        name = self._selected_remote_name()
        if not name:
            messagebox.showinfo("Download", "Select a remote backup")
            return

        remote = f"{self.config_data.storage_path}/{name}"
        local = self.config_data.archive_path / name

        def run() -> None:
            try:
                ssh = self._require_ssh()
                self.after(0, lambda: self._set_busy(True))
                self.after(0, self._reset_progress)
                self.log(f"Downloading {name} -> {local}...")

                def on_progress(pct: int, msg: str) -> None:
                    if pct != self._last_progress_pct or pct >= 100:
                        self._last_progress_pct = pct
                        self.after(0, lambda p=pct, m=msg: self._update_progress("download", p, m))

                ssh.download_dir(remote, local, on_progress=on_progress)
                self.log(f"Saved to {local}")
                self.after(0, self._refresh_local)
            except Exception as exc:
                self.after(0, lambda: messagebox.showerror("Download error", str(exc)))
                self.log(f"Download error: {exc}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        import threading
        threading.Thread(target=run, daemon=True).start()

    def _upload(self) -> None:
        if self._busy:
            return
        name = self._selected_local_name()
        if not name:
            messagebox.showinfo("Upload", "Select a local backup")
            return

        local = self.config_data.archive_path / name
        remote = f"{self.config_data.storage_path}/{name}"

        def run() -> None:
            try:
                ssh = self._require_ssh()
                self.after(0, lambda: self._set_busy(True))
                self.after(0, self._reset_progress)
                self.log(f"Uploading {local} -> {remote}...")

                def on_progress(pct: int, msg: str) -> None:
                    if pct != self._last_progress_pct or pct >= 100:
                        self._last_progress_pct = pct
                        self.after(0, lambda p=pct, m=msg: self._update_progress("upload", p, m))

                ssh.upload_dir(local, remote, on_progress=on_progress)
                self.log(f"Uploaded to {remote}")
                self.after(0, self._refresh_remote)
            except Exception as exc:
                self.after(0, lambda: messagebox.showerror("Upload error", str(exc)))
                self.log(f"Upload error: {exc}")
            finally:
                self.after(0, lambda: self._set_busy(False))

        import threading
        threading.Thread(target=run, daemon=True).start()

    def _delete_remote(self) -> None:
        if self._busy:
            return
        name = self._selected_remote_name()
        if not name:
            messagebox.showinfo("Delete", "Select a remote backup")
            return
        if not self._confirm_delete(name, "remote host"):
            return
        try:
            ssh = self._require_ssh()
            self.log(f"Deleting remote backup {name}...")
            ssh.delete_remote_backup(self.config_data.storage_path, name)
            self.log(f"Deleted {name}")
            self._refresh_remote()
        except Exception as exc:
            messagebox.showerror("Delete error", str(exc))
            self.log(f"Delete error: {exc}")

    def _delete_local(self) -> None:
        if self._busy:
            return
        name = self._selected_local_name()
        if not name:
            messagebox.showinfo("Delete", "Select a local backup")
            return
        if not self._confirm_delete(name, "local archive"):
            return
        try:
            self.log(f"Deleting local backup {name}...")
            SSHClient.delete_local_backup(self.config_data.archive_path, name)
            self.log(f"Deleted {name}")
            self._refresh_local()
        except Exception as exc:
            messagebox.showerror("Delete error", str(exc))
            self.log(f"Delete error: {exc}")

    def _view_log(self, remote: bool) -> None:
        if remote:
            name = self._selected_remote_name()
            if not name:
                return
            try:
                ssh = self._require_ssh()
                out, _, _ = ssh.exec(
                    f'tail -n 100 "{self.config_data.storage_path}/{name}/backup.log" 2>/dev/null; '
                    f'tail -n 50 "{self.config_data.storage_path}/{name}/backup.error.log" 2>/dev/null'
                )
                self._show_text_window(f"Log: {name}", out or "(empty)")
            except Exception as exc:
                messagebox.showerror("Error", str(exc))
        else:
            name = self._selected_local_name()
            if not name:
                return
            log_path = self.config_data.archive_path / name / "backup.log"
            err_path = self.config_data.archive_path / name / "backup.error.log"
            content = ""
            if log_path.exists():
                content += log_path.read_text(encoding="utf-8", errors="replace")
            if err_path.exists():
                content += "\n--- ERROR ---\n" + err_path.read_text(encoding="utf-8", errors="replace")
            self._show_text_window(f"Log: {name}", content or "(empty)")

    def _show_text_window(self, title: str, content: str) -> None:
        win = tk.Toplevel(self)
        win.title(title)
        win.geometry("700x400")
        txt = scrolledtext.ScrolledText(win)
        txt.pack(fill=tk.BOTH, expand=True)
        txt.insert(tk.END, content)
        txt.configure(state=tk.DISABLED)


def _profile_ready(store: ProfileStore) -> bool:
    profile = store.get_active_profile()
    return profile is not None and not profile.validate()


def run_app() -> None:
    store = ProfileStore.load()

    while not _profile_ready(store):
        bootstrap = tk.Tk()
        bootstrap.title("Moo-backup")
        bootstrap.geometry("1x1+0+0")
        bootstrap.overrideredirect(True)
        bootstrap.update_idletasks()

        SettingsDialog(bootstrap, store)
        store = ProfileStore.load()
        bootstrap.destroy()

        if _profile_ready(store):
            break

        prompt = tk.Tk()
        prompt.withdraw()
        prompt.update_idletasks()
        retry = messagebox.askretrycancel(
            "Connections",
            "No connection configured.\n\n"
            "Configure at least one connection to use Moo-backup.\n"
            "Settings are stored in gui/profiles.json next to the application.",
            parent=prompt,
        )
        prompt.destroy()
        if not retry:
            return

    try:
        config = BackuperConfig.load(store)
    except ValueError as exc:
        root = tk.Tk()
        root.withdraw()
        messagebox.showerror("Configuration", str(exc))
        sys.exit(1)

    app = BackuperApp(config, store)
    app.mainloop()
