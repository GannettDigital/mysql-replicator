import socket
import socketserver
import threading
import time
import unittest

from tcp_delay import DelayProxy


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while data := self.request.recv(65536):
            self.request.sendall(data)


class ProxyTests(unittest.TestCase):
    def testDelayPreservesBytesAndHalfClose(self):
        with socketserver.ThreadingTCPServer(("127.0.0.1", 0), Echo) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            proxy = DelayProxy("127.0.0.1", server.server_address[1], 20).start()
            try:
                with socket.create_connection(("127.0.0.1", proxy.listen_port), timeout=5) as client:
                    payload = bytes(range(256)) * 2048
                    start = time.monotonic()
                    client.sendall(payload)
                    client.shutdown(socket.SHUT_WR)
                    received = b""
                    while data := client.recv(65536):
                        received += data
                    self.assertEqual(received, payload)
                    self.assertGreaterEqual(time.monotonic() - start, .018)
            finally:
                proxy.close()
                server.shutdown()
                thread.join(5)
            self.assertFalse(proxy.thread.is_alive())

    def testInvalidDelay(self):
        for value in [-1, 1001]:
            with self.assertRaises(ValueError):
                DelayProxy("127.0.0.1", 1, value)


if __name__ == "__main__":
    unittest.main()
