#!/usr/bin/env bash
set -euo pipefail

codex_bin=${CODEX_BIN:-$(command -v codex 2>/dev/null || true)}
if [[ -z "$codex_bin" ]] \
    || ! "$codex_bin" app-server generate-json-schema --help >/dev/null 2>&1; then
  if [[ ${CODEX_RP_REQUIRE_CONTINUITY_TEST:-no} == yes ]]; then
    printf 'stable session provider routing: failed (Codex app-server required)\n' >&2
    exit 1
  fi
  printf 'stable session provider routing: skipped (Codex app-server unavailable)\n'
  exit 0
fi

python3 - "$codex_bin" <<'PY'
import http.server
import json
import pathlib
import queue
import subprocess
import sys
import tempfile
import threading
import time


class ProbeHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.server.hits.append(self.path)
        length = int(self.headers.get("content-length", "0"))
        request_body = self.rfile.read(length) if length else b""
        self.server.requests.append(request_body)
        self.server.hit_event.set()
        body = b'{"error":{"message":"local continuity probe"}}'
        self.send_response(500)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


class ProbeServer(http.server.ThreadingHTTPServer):
    def __init__(self):
        super().__init__(("127.0.0.1", 0), ProbeHandler)
        self.hits = []
        self.requests = []
        self.hit_event = threading.Event()
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    @property
    def base_url(self):
        return f"http://127.0.0.1:{self.server_port}/v1"

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=2)


class AppServer:
    def __init__(self, codex_bin, codex_home, base_url, model):
        args = [
            codex_bin,
            "app-server",
            "--listen",
            "stdio://",
            "-c",
            'model_provider="stable_session"',
            "-c",
            f'model="{model}"',
            "-c",
            'model_providers.stable_session.name="stable_session"',
            "-c",
            f'model_providers.stable_session.base_url="{base_url}"',
            "-c",
            'model_providers.stable_session.wire_api="responses"',
            "-c",
            "model_providers.stable_session.request_max_retries=0",
        ]
        env = dict(__import__("os").environ)
        env["CODEX_HOME"] = str(codex_home)
        self.process = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=env,
        )
        self.messages = queue.Queue()
        self.stderr = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()
        self._send(
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "session-continuity-test", "version": "1"},
                    "capabilities": {"experimentalApi": True},
                },
            }
        )
        self._wait_for(1)
        self._send({"method": "initialized"})

    def _read_stdout(self):
        for line in self.process.stdout:
            try:
                self.messages.put(json.loads(line))
            except json.JSONDecodeError:
                continue

    def _read_stderr(self):
        for line in self.process.stderr:
            self.stderr.append(line.rstrip())

    def _send(self, message):
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _wait_for(self, request_id, timeout=10):
        deadline = time.monotonic() + timeout
        deferred = []
        try:
            while time.monotonic() < deadline:
                try:
                    message = self.messages.get(timeout=0.1)
                except queue.Empty:
                    if self.process.poll() is not None:
                        raise RuntimeError("app-server exited: " + "\n".join(self.stderr[-10:]))
                    continue
                if message.get("id") == request_id:
                    if "error" in message:
                        raise RuntimeError(json.dumps(message["error"]))
                    return message["result"]
                deferred.append(message)
        finally:
            for message in deferred:
                self.messages.put(message)
        raise TimeoutError(f"timed out waiting for app-server request {request_id}")

    def request(self, request_id, method, params):
        self._send({"id": request_id, "method": method, "params": params})
        return self._wait_for(request_id)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


codex_bin = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="codex-session-continuity-") as temp_dir:
    codex_home = pathlib.Path(temp_dir) / "codex-home"
    codex_home.mkdir(mode=0o700)
    endpoint_a = ProbeServer()
    endpoint_b = ProbeServer()
    first = second = None
    try:
        first = AppServer(codex_bin, codex_home, endpoint_a.base_url, "model-a")
        started = first.request(
            2,
            "thread/start",
            {
                "cwd": temp_dir,
                "model": "model-a",
                "modelProvider": "stable_session",
                "ephemeral": False,
            },
        )
        thread_id = started["thread"]["id"]
        first.request(
            3,
            "turn/start",
            {
                "threadId": thread_id,
                "input": [{"type": "text", "text": "first local routing probe"}],
            },
        )
        if not endpoint_a.hit_event.wait(timeout=5):
            raise RuntimeError("first turn did not reach endpoint A")
        time.sleep(0.2)
        first.close()
        first = None

        second = AppServer(codex_bin, codex_home, endpoint_b.base_url, "model-b")
        listed = second.request(
            2,
            "thread/list",
            {"modelProviders": ["stable_session"], "limit": 20},
        )
        if thread_id not in {thread["id"] for thread in listed["data"]}:
            raise RuntimeError("stable provider filter hid the thread after backend switch")
        resumed = second.request(
            3,
            "thread/resume",
            {
                "threadId": thread_id,
                "model": "model-b",
                "modelProvider": "stable_session",
                "excludeTurns": True,
            },
        )
        if resumed["thread"]["id"] != thread_id:
            raise RuntimeError("resume returned a different thread id")
        if resumed["thread"]["modelProvider"] != "stable_session":
            raise RuntimeError("resume changed the stable session provider id")
        second.request(
            4,
            "turn/start",
            {
                "threadId": thread_id,
                "model": "model-b",
                "input": [{"type": "text", "text": "second local routing probe"}],
            },
        )
        if not endpoint_b.hit_event.wait(timeout=5):
            raise RuntimeError("resumed turn did not reach endpoint B")
        routed_request = endpoint_b.requests[-1].decode("utf-8", errors="replace")
        if "first local routing probe" not in routed_request:
            raise RuntimeError("resumed request omitted the pre-switch transcript")
        if "second local routing probe" not in routed_request:
            raise RuntimeError("resumed request omitted the new turn input")

        rollout_files = list((codex_home / "sessions").rglob("*.jsonl"))
        if len(rollout_files) != 1:
            raise RuntimeError("continuity probe did not preserve one rollout file")
        with rollout_files[0].open(encoding="utf-8") as handle:
            metadata = json.loads(handle.readline())
        if metadata.get("type") != "session_meta":
            raise RuntimeError("rollout does not start with session_meta")
        if metadata["payload"].get("id") != thread_id:
            raise RuntimeError("rollout thread id changed during resume")
        if metadata["payload"].get("model_provider") != "stable_session":
            raise RuntimeError("rollout provider id changed during backend switch")
    finally:
        if first is not None:
            first.close()
        if second is not None:
            second.close()
        endpoint_a.close()
        endpoint_b.close()

print("stable session provider routing: ok")
PY
