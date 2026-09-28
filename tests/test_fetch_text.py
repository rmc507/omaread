# Run with: python3 -m unittest discover -s tests
import http.server
import importlib.machinery
import importlib.util
import threading
import time
import unittest
from pathlib import Path

path = Path(__file__).resolve().parent.parent / "bin" / "fetch-text"
loader = importlib.machinery.SourceFileLoader("fetch_text", str(path))
spec = importlib.util.spec_from_loader("fetch_text", loader)
fetch_text = importlib.util.module_from_spec(spec)
loader.exec_module(fetch_text)


class FakeResponse:
    def __init__(self, body: bytes, length=None):
        self.body = body
        self.length = length

    def getheader(self, name):
        return self.length if name == "Content-Length" else None

    def read(self, size):
        chunk, self.body = self.body[:size], self.body[size:]
        return chunk


class PublicAddressTests(unittest.TestCase):
    def test_non_public_ips_are_rejected(self):
        for ip in ["127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "169.254.169.254",
                   "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fd00::1", "::ffff:127.0.0.1", "224.0.0.1"]:
            self.assertFalse(fetch_text.is_public_ip(ip), ip)

    def test_public_ips_are_allowed(self):
        for ip in ["1.1.1.1", "93.184.216.34", "2606:4700:4700::1111"]:
            self.assertTrue(fetch_text.is_public_ip(ip), ip)

    def test_localhost_names_are_refused(self):
        with self.assertRaises(fetch_text.Fail):
            fetch_text.public_addresses("localhost", 80)

    def test_only_http_schemes(self):
        for url in ["file:///etc/passwd", "ftp://example.com/", "http://"]:
            with self.assertRaises(fetch_text.Fail):
                fetch_text.fetch_html(url)


class LocalServerTests(unittest.TestCase):
    """A real server on loopback must never be reached."""

    def setUp(self):
        self.hits = 0
        test = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                test.hits += 1
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"<p>secret</p>")

            def log_message(self, *args):
                pass

        self.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def test_loopback_url_is_refused_before_connecting(self):
        port = self.server.server_address[1]
        for url in [f"http://127.0.0.1:{port}/", f"http://localhost:{port}/", f"http://[::ffff:127.0.0.1]:{port}/"]:
            with self.assertRaises(fetch_text.Fail):
                fetch_text.fetch_html(url)
        self.assertEqual(self.hits, 0)


class SizeLimitTests(unittest.TestCase):
    def test_reads_within_limit(self):
        self.assertEqual(fetch_text.read_limited(FakeResponse(b"x" * 100), 100, time.monotonic() + 5), b"x" * 100)

    def test_stops_past_limit_while_streaming(self):
        with self.assertRaises(fetch_text.Fail):
            fetch_text.read_limited(FakeResponse(b"x" * 200_000), 100_000, time.monotonic() + 5)

    def test_rejects_oversized_content_length(self):
        with self.assertRaises(fetch_text.Fail):
            fetch_text.read_limited(FakeResponse(b"", length="999999999"), 1000, time.monotonic() + 5)


class ExtractionTests(unittest.TestCase):
    def test_article_text_skips_page_chrome(self):
        page = ("<title>T</title><nav>Menu</nav><main><p>" + "Body text. " * 30 +
                "</p><script>x()</script></main><footer>F</footer>")
        title, text = fetch_text.html_to_text(page, article=True)
        self.assertEqual(title, "T")
        self.assertTrue(text.startswith("Body text."))
        for junk in ("Menu", "x()", "F"):
            self.assertNotIn(junk, text)


if __name__ == "__main__":
    unittest.main()
