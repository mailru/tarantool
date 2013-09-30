import sys
import os

# mask BFD warnings: https://bugs.launchpad.net/tarantool/+bug/1018356
sys.stdout.push_filter("unable to read unknown load command 0x2\d+", "")

server.test_option("--help")
server.test_option("-h")
sys.stdout.push_filter("(/\S+)+/tarantool", "tarantool")
# Test a cfg-get for something that is not in the config
# file (used to crash, Bug#748599
server.test_option("--cfg-get=custom_proc_title")
server.test_option("-Z")
server.test_option("--no-such-option")
server.test_option("--version --no-such-option")
server.test_option("--config")
server.test_option("-c")
server.test_option("--config tarantool.cfg")
server.test_option("--daemonize")
server.test_option("--background")
print """#
# Check that --background  doesn't work if there is no logger
# This is a test case for
# https://bugs.launchpad.net/tarantool/+bug/750658
# "--background neither closes nor redirects stdin/stdout/stderr"
#"""
cfg = os.path.join(vardir, "tarantool_bug750658.cfg")
os.symlink(os.path.abspath("box/tarantool_bug750658.cfg"), cfg)
server.test_option("--config=tarantool_bug750658.cfg --background")
os.unlink(cfg)
sys.stdout.pop_filter()
sys.stdout.push_filter("(\d)\.\d\.\d(-\d+-\w+)?", "\\1.minor.patch-<rev>-<commit>")
sys.stdout.push_filter("Target: .*", "Target: platform <build>")
sys.stdout.push_filter("Build options: .*", "Build options: flags")
sys.stdout.push_filter("C_FLAGS:.*", "C_FLAGS: flags")
sys.stdout.push_filter("CXX_FLAGS:.*", "CXX_FLAGS: flags")
sys.stdout.push_filter("Compiler: .*", "Compiler: cc")

server.test_option("--version")
server.test_option("-V          ")
sys.stdout.clear_all_filters()

print """#
# A test case for Bug#726778 "Gopt broke wal_dir and snap_dir: they are no
# longer relative to work_dir".
# https://bugs.launchpad.net/tarantool/+bug/726778
# After addition of gopt(), we started to chdir() to the working
# directory after option parsing.
# Verify that this is not the case, and snap_dir and xlog_dir
# can be relative to work_dir.
"""
import shutil
shutil.rmtree(os.path.join(vardir, "bug726778"), True)
cfg = os.path.join(vardir, "bug726778.cfg")
os.mkdir(os.path.join(vardir, "bug726778"))
os.mkdir(os.path.join(vardir, "bug726778/snapshots"))
os.mkdir(os.path.join(vardir, "bug726778/xlogs"))

os.symlink(os.path.abspath("box/bug726778.cfg"), cfg)

sys.stdout.push_filter("(/\S+)+/tarantool", "tarantool")
sys.stdout.push_filter(".*(P|p)lugin.*", "")
server.test_option("--config=bug726778.cfg --init-storage")
sys.stdout.pop_filter()

os.unlink(cfg)
shutil.rmtree(os.path.join(vardir, "bug726778"))

print """#
# A test case for Bug#897162, cat command should
# not require a configuration file.
"""
sys.stdout.push_filter("(/\S+)+/tarantool", "tarantool")
server.test_option("--config=nonexists.cfg --cat=nonexists.xlog")
sys.stdout.pop_filter()

# Args filter cleanup
# vim: syntax=python
