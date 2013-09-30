import os
import re
import sys
import glob
import traceback
import subprocess
from subprocess import Popen, PIPE

from server import Server
from test_suite import FilteredStream, Test

class UnitTest(Test):
    def execute(self, server):
        execs = [os.path.join(server.builddir, "test", self.name)]
        proc = Popen(execs, stdout=PIPE)
        sys.stdout.write(proc.communicate()[0])

class UnittestServer(Server):
    """A dummy server implementation for unit test suite"""
    def __new__(cls, core="unittest"):
        return Server.__new__(cls)

    def __init__(self, core="unittest"):
        Server.__init__(self, core)
        self.debug = False

    def deploy(self, config=None, binary=None, vardir=None,
               mem=None, start_and_exit=None, gdb=None, valgrind=None,
               valgrind_sup=None, init_lua=None, silent=True, need_init=True):
        self.vardir = vardir
        if not os.access(self.vardir, os.F_OK):
            os.makedirs(self.vardir)

    def find_exe(self, builddir, silent=False):
        self.builddir = builddir

    def find_tests(self, test_suite, suite_path):
        def patterned(test, patterns):
            answer = []
            for i in patterns:
                if test.name.find(i) != -1:
                    answer.append(test)
            return answer

        test_suite.tests = [UnitTest(k, test_suite.args, test_suite.ini) for k in sorted(glob.glob(os.path.join(suite_path, "*.test" )))]
        test_suite.tests = sum(map((lambda x: patterned(x, test_suite.args.tests)), test_suite.tests), [])
