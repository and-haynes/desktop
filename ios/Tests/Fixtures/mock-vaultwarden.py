#!/usr/bin/env python3
"""A mock Vaultwarden, for exercising the vault against a real network (#008AD).

No Bitwarden account and no Vaultwarden instance is reachable from the machine
this app is built on, so the unit tests mock `URLProtocol`. That is the right
call for tests, but it leaves one thing unproven: whether the *app*, driven by
hand through its own settings screen, can connect to something speaking the
Bitwarden protocol and show real logins. This is what the screenshots in
`docs/screenshots/36-38` are taken against.

It is a mock, not a reimplementation. It serves exactly the three endpoints the
client calls and no more:

    POST /identity/accounts/prelogin   -> the account's KDF parameters
    POST /identity/connect/token       -> an access token and the protected key
    GET  /api/sync?excludeDomains=true -> the vault

What it does do honestly is the **crypto**. The vault is encrypted here the way
a real server's vault is encrypted, so the app performs a genuine PBKDF2 run,
genuine HKDF key stretching, a genuine user-key unwrap and genuine
AES-256-CBC-then-HMAC decryption of every field. Nothing about the client path
is stubbed. If the port from Ghostty were wrong, this would fail to decrypt.

Crypto with the standard library plus the `openssl` command, because this Mac
has neither `cryptography` nor `pycryptodome` installed and a fixture server is
not a good reason to add a dependency:

    - PBKDF2-SHA256 and HMAC-SHA256 from `hashlib`/`hmac`
    - HKDF-Expand written out (RFC 5869 §2.3 — one block, for a 32-byte output)
    - AES-256-CBC through `openssl enc`

Run it from `ios/`:

    python3 Tests/Fixtures/mock-vaultwarden.py

It reuses the CA that `serve.py` mints, so the simulator trusts it after:

    xcrun simctl keychain <udid> add-root-cert /tmp/zensync-fixtures/ca.pem

Then in Zen: Settings -> Passwords -> Connect a Vault -> Bitwarden/Vaultwarden,
server `https://zen.localtest.me:8445`, the email and master password printed
at startup, and "Allow a self-signed certificate" on.
"""

import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
import ssl
import subprocess
import sys
import urllib.parse
import uuid

# The account. Printed at startup so the set-up sheet can be filled in.
EMAIL = "andy@example.com"
MASTER_PASSWORD = "correct-horse-battery-staple"
# Real Bitwarden defaults to 600 000. 100 000 is a real KDF run — enough to
# prove the path — without making every screenshot wait on a simulator.
KDF_ITERATIONS = 100_000

PORT = 8445
CERT_DIR = "/tmp/zensync-fixtures"


# --------------------------------------------------------------------------
# Crypto
# --------------------------------------------------------------------------


def pbkdf2(password: bytes, salt: bytes, iterations: int, length: int) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", password, salt, iterations, dklen=length)


def hkdf_expand(prk: bytes, info: bytes, length: int = 32) -> bytes:
    """RFC 5869 §2.3, expand only.

    Bitwarden skips the extract step because the master key is already a
    uniformly random KDF output. For a 32-byte output this is a single HMAC —
    T(1) = HMAC(prk, info || 0x01).
    """
    assert length <= 32, "one block only"
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


def aes_cbc_encrypt(plaintext: bytes, key: bytes, iv: bytes) -> bytes:
    """AES-256-CBC with PKCS#7, via the openssl command."""
    result = subprocess.run(
        [
            "openssl", "enc", "-aes-256-cbc", "-nosalt",
            "-K", key.hex(), "-iv", iv.hex(),
        ],
        input=plaintext,
        capture_output=True,
        check=True,
    )
    return result.stdout


def enc_string(plaintext: str, enc_key: bytes, mac_key: bytes) -> str:
    """Bitwarden's type-2 EncString: `2.<iv>|<ciphertext>|<mac>`, base64.

    Encrypt-then-MAC over `iv || ciphertext`, which is the order the client
    verifies in — it authenticates before it decrypts, so that a CBC padding
    oracle never gets a chance to exist.
    """
    iv = os.urandom(16)
    ciphertext = aes_cbc_encrypt(plaintext.encode("utf-8"), enc_key, iv)
    tag = hmac.new(mac_key, iv + ciphertext, hashlib.sha256).digest()
    return "2.{}|{}|{}".format(
        base64.b64encode(iv).decode(),
        base64.b64encode(ciphertext).decode(),
        base64.b64encode(tag).decode(),
    )


def build_vault():
    """Derive the account's keys and encrypt a small vault under them."""
    salt = EMAIL.strip().lower().encode("utf-8")
    master_key = pbkdf2(MASTER_PASSWORD.encode("utf-8"), salt, KDF_ITERATIONS, 32)

    # What the server stores to check the password. One iteration is enough:
    # the input is already a 256-bit KDF output, not a human password.
    master_password_hash = base64.b64encode(
        pbkdf2(master_key, MASTER_PASSWORD.encode("utf-8"), 1, 32)
    ).decode()

    stretched_enc = hkdf_expand(master_key, b"enc")
    stretched_mac = hkdf_expand(master_key, b"mac")

    # The user key: what every cipher is really encrypted with. Wrapping it
    # under the stretched master key is why changing a master password
    # re-wraps 64 bytes instead of re-encrypting the whole vault.
    user_key = os.urandom(64)
    user_enc, user_mac = user_key[:32], user_key[32:]
    # The protected key wraps the *raw* 64 bytes, not a base64 string of them:
    # the client splits what it decrypts straight into a 32-byte enc half and a
    # 32-byte mac half, so anything textual here fails its length check with a
    # message about the wrong master password.
    iv = os.urandom(16)
    ciphertext = aes_cbc_encrypt(user_key, stretched_enc, iv)
    tag = hmac.new(stretched_mac, iv + ciphertext, hashlib.sha256).digest()
    protected_key = "2.{}|{}|{}".format(
        base64.b64encode(iv).decode(),
        base64.b64encode(ciphertext).decode(),
        base64.b64encode(tag).decode(),
    )

    def enc(value):
        return enc_string(value, user_enc, user_mac)

    folder_id = str(uuid.uuid4())

    def login(name, username, password, uri, totp=None, match=None,
              organization_id=None, folder=folder_id, deleted=None, kind=1):
        cipher = {
            "id": str(uuid.uuid4()),
            "organizationId": organization_id,
            "folderId": folder,
            "type": kind,
            "name": enc(name),
            "notes": None,
            "favorite": False,
            "reprompt": 0,
            "revisionDate": "2026-09-14T12:00:00.0000000Z",
            "deletedDate": deleted,
            "login": {
                "username": enc(username) if username else None,
                "password": enc(password) if password else None,
                "totp": enc(totp) if totp else None,
                "uris": [{"uri": enc(uri), "match": match}],
            },
        }
        return cipher

    ciphers = [
        login("GitHub", "andy", "hunter2-github", "https://github.com",
              totp="otpauth://totp/GitHub:andy?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
        login("Vaultwarden", "andy@example.com", "correct-horse", "https://vault.lan"),
        login("Homelab router", "admin", "unifi-admin-pw", "https://10.0.0.1"),
        login("Proxmox", "root@pam", "proxmox-pw", "https://10.0.0.80:8006"),
        login("Zen fixture login", "andy@example.com", "fixture-password",
              "https://zen.localtest.me",
              totp="otpauth://totp/Zen:andy?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"),
        login("Tickets", "andy", "tix-pw", "https://tickets.lan"),
        # Unreadable by construction: an organisation cipher's key is one this
        # client never unwraps. It must be skipped and counted, not fatal.
        login("Shared billing", "billing", "x", "https://billing.example.com",
              organization_id=str(uuid.uuid4())),
        # In the trash, and therefore gone as far as the panel is concerned.
        login("Old account", "andy", "x", "https://old.example.com",
              deleted="2026-09-01T12:00:00.0000000Z"),
        # Not a login at all — a secure note. Filtered on type.
        login("A note", None, None, "https://notes.example.com", kind=2),
    ]

    profile = {
        "id": str(uuid.uuid4()),
        "email": EMAIL,
        "name": "Andy",
        "key": protected_key,
    }
    folders = [{"id": folder_id, "name": enc("Homelab")}]

    return {
        "masterPasswordHash": master_password_hash,
        "protectedKey": protected_key,
        "sync": {
            "profile": profile,
            "folders": folders,
            "ciphers": ciphers,
            "collections": [],
            "policies": [],
            "sends": [],
            "domains": None,
            "object": "sync",
        },
    }


VAULT = build_vault()


# --------------------------------------------------------------------------
# Server
# --------------------------------------------------------------------------


class Handler(http.server.BaseHTTPRequestHandler):
    def _json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        path = urllib.parse.urlparse(self.path).path

        if path.endswith("/accounts/prelogin"):
            # Per-account, never a default: an old account may still be on
            # 100 000 iterations while the server's default is 600 000.
            return self._json({"kdf": 0, "kdfIterations": KDF_ITERATIONS})

        if path.endswith("/connect/token"):
            form = urllib.parse.parse_qs(raw.decode("utf-8"))
            supplied = (form.get("password") or [""])[0]
            if supplied != VAULT["masterPasswordHash"]:
                # What a real server says for a wrong password, so the app's
                # error path is exercised by typing one.
                return self._json(
                    {
                        "error": "invalid_grant",
                        "error_description": "invalid_username_or_password",
                        "ErrorModel": {"Message": "Username or password is incorrect."},
                    },
                    status=400,
                )
            return self._json(
                {
                    "access_token": "mock-access-token",
                    "expires_in": 3600,
                    "token_type": "Bearer",
                    "refresh_token": "mock-refresh-token",
                    "Key": VAULT["protectedKey"],
                    "Kdf": 0,
                    "KdfIterations": KDF_ITERATIONS,
                }
            )

        # Creating a cipher: accept it and hand back what was sent, with an id.
        if path.endswith("/ciphers"):
            try:
                sent = json.loads(raw.decode("utf-8"))
            except ValueError:
                sent = {}
            sent["id"] = str(uuid.uuid4())
            sent["revisionDate"] = "2026-09-15T12:00:00.0000000Z"
            VAULT["sync"]["ciphers"].append(sent)
            return self._json(sent)

        self._json({"message": "Not found"}, status=404)

    def do_PUT(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length)
        try:
            sent = json.loads(raw.decode("utf-8"))
        except ValueError:
            sent = {}
        identifier = urllib.parse.urlparse(self.path).path.rstrip("/").split("/")[-1]
        sent["id"] = identifier
        sent["revisionDate"] = "2026-09-15T12:00:00.0000000Z"
        for index, cipher in enumerate(VAULT["sync"]["ciphers"]):
            if cipher.get("id") == identifier:
                VAULT["sync"]["ciphers"][index] = sent
                break
        self._json(sent)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path.endswith("/sync"):
            return self._json(VAULT["sync"])
        self._json({"message": "Not found"}, status=404)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main():
    parser = argparse.ArgumentParser(description="A mock Vaultwarden (#008AD).")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument(
        "--cert", default=os.path.join(CERT_DIR, "server.pem"),
        help="PEM holding the leaf certificate and its key")
    options = parser.parse_args()

    server_pem = options.cert
    if not os.path.exists(server_pem):
        sys.exit(
            "No certificate at {}. Run `python3 Tests/Fixtures/serve.py` once "
            "to mint one.".format(server_pem)
        )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(server_pem)
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", options.port), Handler)
    httpd.socket = context.wrap_socket(httpd.socket, server_side=True)

    print("mock Vaultwarden on https://zen.localtest.me:{}".format(options.port))
    print("  email:           {}".format(EMAIL))
    print("  master password: {}".format(MASTER_PASSWORD))
    print("  KDF:             PBKDF2-SHA256, {} iterations".format(KDF_ITERATIONS))
    print("  logins:          {}".format(len(VAULT["sync"]["ciphers"])))
    httpd.serve_forever()


if __name__ == "__main__":
    main()
