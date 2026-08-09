# Prompt for migrating this setup with Codex

Copy the `codex-remote-provider-kit` directory to the target Linux server, open
Codex in that directory, and paste the prompt below.

---

Inspect this server and migrate Codex Remote to the custom Responses API using
the scripts in the current `codex-remote-provider-kit` directory.

Target settings:

- Base URL: `https://ai.inno-flare.com/v1`
- Provider id: `inno_flare`
- Model: `gpt-5.6-sol`
- Key environment variable: `INNO_FLARE_API_KEY`
- Reasoning effort: `high`

Safety and workflow requirements:

1. Read `README.md` completely before acting.
2. Inspect the Codex version, `codex remote-control start --help`, ChatGPT login
   status, user-level `$CODEX_HOME/config.toml`, existing Remote processes, and
   relevant systemd units. Never print credentials or complete process
   environments.
3. Explain that Remote still requires official ChatGPT login/control-plane
   access, while inference data will be sent to the third-party provider.
4. Require my explicit authorization before routing Remote prompts, code, files,
   or tool results to the third party.
5. Do not accept an API key in chat or place it in a command line. Ask me to set
   `INNO_FLARE_API_KEY` interactively with `read -rsp`, then run the installer
   through `sudo -E`.
6. Back up all overlapping configuration and record existing service state.
7. Run `bash -n` on every script before installation.
8. Run `install.sh` with the target settings, then run `status.sh --full`.
9. Confirm three independent layers: `/v1/models`, one streamed
   `/v1/responses` request, and one real ephemeral `codex exec` request.
10. Confirm Remote reports `connected`. Ask me to create a new phone chat and
    send `Reply exactly OK`; do not open a thread that has another active writer.
11. Do not implement automatic provider failover because it could unexpectedly
    consume official quota. Verify `use-official.sh`, `use-third-party.sh`, and
    `rollback.sh` as the explicit recovery paths.
12. If anything fails, preserve logs with credentials redacted and restore the
    prior state. Never delete session history to solve an active-writer conflict.

Finish with the installed paths, verification evidence, remaining compatibility
warnings, and exact rollback command.
