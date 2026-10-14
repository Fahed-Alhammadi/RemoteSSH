import sys
from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import TLS_FTPHandler
from pyftpdlib.servers import FTPServer

root, cert, key = sys.argv[1:4]
auth = DummyAuthorizer()
auth.add_user("tester", "secret", root, perm="elradfmwMT")
h = TLS_FTPHandler
h.authorizer = auth
h.certfile = cert
h.keyfile = key
h.tls_control_required = False   # explicit TLS optional (AUTH TLS)
h.tls_data_required = False
h.passive_ports = range(30000, 30050)
FTPServer(("127.0.0.1", 2121), h).serve_forever()
