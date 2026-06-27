Check the moo-backup project for publication readiness and prepare a commit.

Steps to perform in order:

1. **Check dates.** Read the first 10 lines of README.md and PLAN.md. The line `**Последнее обновление:**` must match today's date in Russian (e.g. "28 июня 2026"). If stale, update both files.

2. **Check git status.** Run `git status` and `git diff`. List all modified and untracked files.

3. **Security check.** Confirm that `gui/profiles.json` and `gui/keys/` are NOT staged and NOT tracked. If either appears in staged changes, stop and warn — do not proceed with a commit.

4. **License files check.** Confirm `LICENSE` and `moodle-plugin/LICENSE.txt` exist on disk.

5. **Report.** Summarize: what's ready, what was updated, what will be committed. Show proposed commit message following the project style (e.g. `fix: ...`, `feat: ...`, `docs: ...`).

6. **Stage and commit** the relevant files. Do NOT push — only commit locally.

Do not push to GitHub. Do not delete any files. Do not modify files outside the project directory.
