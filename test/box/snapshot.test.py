import os
import yaml
import time
from signal import SIGUSR1

admin("space = box.schema.create_space('tweedledum', { id = 0 })")
admin("space:create_index('primary', 'hash', { parts = { 0, 'num' }})")

print """#
# A test case for: http://bugs.launchpad.net/bugs/686411
# Check that 'box.snapshot()' does not overwrite a snapshot
# file that already exists. Verify also that any other
# error that happens when saving snapshot is propagated
# to the caller.
"""
admin("box.insert(0, 1, 'first tuple')")
admin("box.snapshot()")

# In absence of data modifications, two consecutive
# 'box.snapshot()' statements will try to write
# into the same file, since file name is based
# on LSN.
#  Don't allow to overwrite snapshots.
admin("box.snapshot()")
#
# Increment LSN
admin("box.insert(0, 2, 'second tuple')")
#
# Check for other errors, e.g. "Permission denied".
print "# Make 'var' directory read-only."
os.chmod(vardir, 0555)
admin("box.snapshot()")

# cleanup
os.chmod(vardir, 0755)

admin("box.delete(0, 1)")
admin("box.delete(0, 2)")

print """#
# A test case for http://bugs.launchpad.net/bugs/727174
# "tarantool_box crashes when saving snapshot on SIGUSR1"
#"""

print """
# Increment the lsn number, to make sure there is no such snapshot yet
#"""

admin("box.insert(0, 1, 'Test tuple')")

pid = int(yaml.load(admin("box.info.pid", silent=True))[0])
lsn = yaml.load(admin("box.info.lsn", silent=True))[0]

snapshot = str(lsn).zfill(20) + ".snap"
snapshot = os.path.join(vardir, snapshot)

iteration = 0

MAX_ITERATIONS = 100

while not os.access(snapshot, os.F_OK) and iteration < MAX_ITERATIONS:
  if iteration % 10 == 0:
    os.kill(pid, SIGUSR1)
  time.sleep(0.1)
  iteration = iteration + 1

if iteration == 0 or iteration >= MAX_ITERATIONS:
  print "Snapshot is missing."
else:
  print "Snapshot exists."

admin("box.space[0]:drop()")
