"""Regression tests for the container-side installer."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


INSTALLER = (Path(__file__).parents[1] / "install-huf-lxc.sh").read_text()


class RootSshLifecycleTests(unittest.TestCase):
    def test_root_ssh_does_not_reload_an_inactive_service(self):
        """A selected root-SSH option must not fail a successful HUF install."""
        expected = '''if systemctl is-active --quiet ssh; then
    systemctl reload ssh
  else
    systemctl enable --now ssh
  fi'''
        self.assertIn(expected, INSTALLER)

    def test_tailnet_socketio_preserves_the_browser_origin(self):
        """Serve TLS must not be rewritten to local HTTP before CORS validation."""
        self.assertIn(
            "sed -i '\\#proxy_set_header Origin \\$scheme://\\$http_host;#d' \"$NGINX_CONF\"",
            INSTALLER,
        )
        self.assertNotIn('map $host $huf_socketio_origin {', INSTALLER)
        self.assertNotIn('proxy_set_header Origin $huf_socketio_origin;', INSTALLER)

    def test_installer_applies_guarded_huf_socket_frontend_fix(self):
        """Fresh installs must not expose Frappe's internal port 9000 to browsers."""
        self.assertIn('HUF_SOCKET_CONTEXT=', INSTALLER)
        self.assertIn("window.location?.port || ''", INSTALLER)
        self.assertIn("HUF frontend Socket.IO source differs; leaving it unchanged.", INSTALLER)


def _socket_patch_script():
    start = INSTALLER.index("python3 - \"$HUF_SOCKET_CONTEXT\" <<'PY'\n")
    start = INSTALLER.index("\n", start) + 1
    return INSTALLER[start:INSTALLER.index("\nPY\n", start)]


UPSTREAM = """      const port =
        (window as FrappeWindow).frappe?.boot?.socketio_port ||
        window.location?.port ||
        '9000';"""
LEGACY_PATCHED = """      // Production reverse proxies use the page origin for Socket.IO.
      // A non-empty page port is retained for local development.
      const port = window.location?.port || '';"""
NOTICE = "// Modified by huf-proxmox-helper (https://github.com/SahilUX/huf-proxmox-helper), "


class SocketPatchTests(unittest.TestCase):
    def run_patch(self, body):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "SocketContext.tsx"
            path.write_text(f"before\n{body}\nafter\n")
            out = subprocess.run(
                [sys.executable, "-I", "-", str(path)],
                input=_socket_patch_script(), text=True, capture_output=True, check=True,
            ).stdout
            return out, path.read_text()

    def test_upstream_text_is_patched_with_notice(self):
        out, text = self.run_patch(UPSTREAM)
        self.assertIn("Applied guarded HUF Socket.IO frontend patch.", out)
        self.assertIn(NOTICE, text)
        self.assertIn("AGPL-3.0 section 5.", text)
        self.assertNotIn("'9000'", text)
        self.assertEqual(text.count("const port ="), 1)
        rerun_out, rerun_text = self.run_patch(text.removeprefix("before\n").removesuffix("\nafter\n"))
        self.assertIn("already present.", rerun_out)
        self.assertEqual(rerun_text, text)

    def test_legacy_patched_text_is_recognised(self):
        out, text = self.run_patch(LEGACY_PATCHED)
        self.assertIn("HUF Socket.IO frontend patch is already present", out)
        self.assertNotIn("source differs", out)
        self.assertEqual(text.count(NOTICE), 1)
        self.assertEqual(text.count("const port ="), 1)

    def test_unrelated_text_is_left_unchanged(self):
        out, text = self.run_patch("const port = 1234;")
        self.assertIn("source differs; leaving it unchanged.", out)
        self.assertEqual(text, "before\nconst port = 1234;\nafter\n")


if __name__ == "__main__":
    unittest.main()
