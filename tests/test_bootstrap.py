import base64
import os
import re
import socket
import struct
import sys
import threading

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from controller import app, ike_probe


def render(**ss):
    return base64.b64decode(app.build_user_data({"password": "pw+/=", **ss}, "psk_x-1")).decode()


def test_all_placeholders_filled():
    script = render()
    assert not re.findall(r"\{\{[A-Z_]+\}\}", script)
    assert "IKEV2_PSK='psk_x-1'" in script and "SS_PASSWORD='pw+/='" in script


@pytest.mark.parametrize("bad", ["a'b", "a b", "$(reboot)", 'a"b', ""])
def test_rejects_shell_unsafe_values(bad):
    with pytest.raises(ValueError):
        render(password=bad)


def _responder(reply_first_payload):
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", 0))

    def serve():
        data, addr = srv.recvfrom(4096)
        header = data[:8] + os.urandom(8) + struct.pack("!BBBBII", reply_first_payload, 0x20, 34, 0x20, 0, 36)
        body = struct.pack("!BBHBBH", 0, 0, 8, 0, 0, 14) if reply_first_payload == 41 else b"\0" * 8
        srv.sendto(header + body, addr)
        srv.close()

    threading.Thread(target=serve, daemon=True).start()
    return srv.getsockname()[1]


def test_probe_accepts_sa_reply():
    assert ike_probe.probe("127.0.0.1", _responder(33), timeout=2) == "accepted"


def test_probe_reports_notify():
    assert ike_probe.probe("127.0.0.1", _responder(41), timeout=2) == "notify:14"


def test_probe_none_without_responder():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    assert ike_probe.probe("127.0.0.1", port, timeout=1) is None
