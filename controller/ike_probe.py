"""Send a real IKEv2 IKE_SA_INIT (iOS default suite: AES-256/SHA2-256/DH14) and parse the reply."""
import os
import socket
import struct

SA, KE, NONCE, NOTIFY = 33, 34, 40, 41
IKE_SA_INIT = 34


def _transform(ttype, tid, attrs=b"", last=False):
    return struct.pack("!BBHBBH", 0 if last else 3, 0, 8 + len(attrs), ttype, 0, tid) + attrs


def _payload(next_payload, body):
    return struct.pack("!BBH", next_payload, 0, 4 + len(body)) + body


def build_init(spi):
    transforms = (
        _transform(1, 12, struct.pack("!HH", 0x800E, 256))  # ENCR AES-CBC-256
        + _transform(2, 5)  # PRF HMAC-SHA2-256
        + _transform(3, 12)  # INTEG HMAC-SHA2-256-128
        + _transform(4, 14, last=True)  # DH MODP-2048
    )
    proposal = struct.pack("!BBHBBBB", 0, 0, 8 + len(transforms), 1, 1, 0, 4) + transforms
    ke_value = b"\x7f" + os.urandom(255)
    body = (
        _payload(KE, proposal)
        + _payload(NONCE, struct.pack("!HH", 14, 0) + ke_value)
        + _payload(0, os.urandom(32))
    )
    header = struct.pack("!8s8sBBBBII", spi, b"\0" * 8, SA, 0x20, IKE_SA_INIT, 0x08, 0, 28 + len(body))
    return header + body


def probe(host, port=500, timeout=5, attempts=3):
    """UDP can drop a single packet; retry before concluding there's no responder."""
    for _ in range(attempts):
        result = _probe_once(host, port, timeout)
        if result is not None:
            return result
    return None


def _probe_once(host, port, timeout):
    """Returns 'accepted' (responder chose our SA), 'notify:<type>', or None (no reply)."""
    spi = os.urandom(8)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.sendto(build_init(spi), (host, port))
        data, _ = s.recvfrom(65535)
    except OSError:
        return None
    finally:
        s.close()
    if len(data) < 28 or data[:8] != spi or data[18] != IKE_SA_INIT or not data[19] & 0x20:
        return None
    first = data[16]
    if first == SA:
        return "accepted"
    if first == NOTIFY and len(data) >= 36:
        return f"notify:{struct.unpack('!H', data[34:36])[0]}"
    return f"payload:{first}"
