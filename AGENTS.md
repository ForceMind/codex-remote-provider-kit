# Repository instructions

- Read `README.md`, `SECURITY.md`, and the relevant file under `docs/` before changes.
- Never print, read into output, commit, or request API keys in chat.
- Preserve explicit official/third-party switching; do not add automatic failover.
- Keep provider configuration at user-level Codex config, not project-level config.
- Keep the user-level top-level `model_provider` synchronized with the selected Remote mode.
- Keep scripts compatible with Bash and validate every shell script with `bash -n`.
- Keep `setup.sh` as the safe one-command entry point; defaults must never contain a credential.
- Before committing, inspect the staged diff and run the repository validation workflow locally.
- Do not delete Codex sessions to resolve an active-writer conflict.
