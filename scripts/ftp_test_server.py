#!/usr/bin/env python3
"""Throwaway local FTP servers for the live tests. Needs: pip install pyftpdlib pyopenssl

  2121  normal FTP, passive and active both work
  2122  refuses passive, so only active works
  2123  explicit FTPS
"""
import os
import sys

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler
from pyftpdlib.servers import FTPServer

root = sys.argv[1]
cert = sys.argv[2]


class NoPassive(FTPHandler):
    def ftp_PASV(self, line):
        self.respond("502 Passive mode refused for this test.")

    def ftp_EPSV(self, line):
        self.respond("502 Passive mode refused for this test.")


def serve(handler_base, port, **attrs):
    authorizer = DummyAuthorizer()
    authorizer.add_user("tester", "secret", root, perm="elradfmwMT")
    authorizer.add_anonymous(root, perm="elradfmwMT")
    handler = type("Handler", (handler_base,), {"authorizer": authorizer, "banner": "test", **attrs})
    if handler_base is TLS_FTPHandler:
        handler.certfile = cert
    # Single threaded on purpose: pyftpdlib's threaded server shares one working folder between clients.
    FTPServer(("127.0.0.1", port), handler).serve_forever()


if os.fork() == 0:
    serve(NoPassive, 2122)
elif os.fork() == 0:
    serve(TLS_FTPHandler, 2123, tls_control_required=True, tls_data_required=True)
else:
    serve(FTPHandler, 2121)
