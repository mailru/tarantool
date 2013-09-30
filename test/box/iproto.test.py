import os
import sys
import struct
import socket

print """
#
# iproto packages test
#
"""

# opeing new connection to tarantool/box
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(('localhost', server.primary_port))

print """
# Test bug #899343 (server assertion failure on incorrect packet)
"""
print "# send the package with invalid length"
inval_request = struct.pack('<LLL', 17, 4294967290, 1)
print s.send(inval_request)
print "# check that is server alive"
sql("ping")

# closing connection
s.close()
