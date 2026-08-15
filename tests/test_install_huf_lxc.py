"""Regression tests for the container-side installer."""
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
