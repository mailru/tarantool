import subprocess
import sys
import os

from lib.tarantool_server import TarantoolServer

p = subprocess.Popen([os.path.join(builddir, "test/connector_c/xlog"),
		              os.path.abspath("connector_c/connector.xlog")],
                     stdout=subprocess.PIPE)
o,e = p.communicate()
sys.stdout.write(o)

server.stop()
server.deploy("connector_c/cfg/master.cfg")
server.stop()

current_xlog = os.path.join(vardir, "00000000000000000002.xlog")
os.symlink(os.path.abspath("connector_c/connector.xlog"), current_xlog)

server.start()

print ""

p = subprocess.Popen([os.path.join(builddir, "test/connector_c/rpl"),
                      "127.0.0.1", "33016", "1200"],
                     stdout=subprocess.PIPE)
o,e = p.communicate()
sys.stdout.write(o)

server.stop()
server.deploy()

# vim: syntax=python
