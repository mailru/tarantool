-------------------------------------------------------------------------------
                        Server administration
-------------------------------------------------------------------------------

Typical server administration tasks include starting and stopping the server,
reloading configuration, taking snapshots, log rotation.

=====================================================================
                        Server signal handling
=====================================================================

The server is configured to shut down gracefully on SIGTERM and SIGINT
(keyboard interrupt). SIGUSR1 can be used to save a snapshot. All
other signals are blocked or ignored. The signals are processed in the main
thread event loop. Thus, if the control flow never reaches the event loop
(thanks to a runaway stored procedure), the server stops responding to any
signal, and can only be killed with SIGKILL (this signal can not be ignored).

=====================================================================
                        Using ``tarantool`` as a client
=====================================================================

.. program:: tarantool

If ``tarantool`` is started without a Lua script to run, it automatically
enters interactive mode. There will be a prompt ("``tarantool>``") and it will
be possible to enter requests. When used this way, ``tarantool`` can be 
a client for a remote server.

This section shows all legal syntax for the tarantool program, with short notes
and examples. Other client programs may have similar options and request
syntaxes. Some of the information in this section is duplicated in the
:ref:`book-cfg` chapter.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            Conventions used in this section
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Tokens are character sequences which are treated as syntactic units within
requests. Square brackets [ and ] enclose optional syntax. Three dots in a
row ... mean the preceding tokens may be repeated. A vertical bar | means
the preceding and following tokens are mutually exclusive alternatives.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Options when starting client from the command line
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

General form:

| :codenormal:`$` :codebold:`tarantool`
| OR
| :codenormal:`$` :codebold:`tarantool` :codebolditalic:`options`
| OR
| :codenormal:`$` :codebold:`tarantool` :codebolditalic:`Lua-initialization-file` :codebold:`[` :codebolditalic:`arguments` :codebold:`]`

:codebolditalic:`Lua-initialization-file` can be any script containing code for initializing.
Effect: The code in the file is executed during startup. Example: ``init.lua``.
Notes: If a script is used, there will be no prompt. The script should contain
configuration information including ``box.cfg{...listen=...}`` or
``box.listen(...)`` so that a separate program can connect to the server via
one of the ports.

Option is one of the following (in alphabetical order by the long form of the
option):

.. option:: -?, -h, --help

    Client displays a help message including a list of options.
    Example: :codenormal:`tarantool --help`.
    The program stops after displaying the help.

.. option:: -V, --version

    Client displays version information.
    Example: :codenormal:`tarantool --version`.
    The program stops after displaying the version.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      Tokens, requests, and special key combinations
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Procedure identifiers are: Any sequence of letters, digits, or underscores
which is legal according to the rules for Lua identifiers. Procedure
identifiers are also called function names. Notes: function names are case
sensitive so ``insert`` and ``Insert`` are not the same thing.

String literals are: Any sequence of zero or more characters enclosed in
single quotes. Double quotes are legal but single quotes are preferred.
Enclosing in double square brackets is good for multi-line strings as
described in `Lua documentation`_. Examples: 'Hello, world', 'A', [[A\\B!]].

.. _Lua documentation: http://www.lua.org/pil/2.4.html

Numeric literals are: Character sequences containing only digits, optionally
preceded by + or -. Examples: 55, -. Notes: Tarantool NUM data type is
unsigned, so -1 is understood as a large unsigned number.

Single-byte tokens are: * or , or ( or ). Examples: * , ( ).

Tokens must be separated from each other by one or more spaces, except that
spaces are not necessary around single-byte tokens or string literals.

.. _setting delimiter:

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                        Requests
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Generally requests are entered following the prompt in interactive mode while
``tarantool`` is running. (A prompt will be the word tarantool and a
greater-than sign, for example ``tarantool>``). The end-of-request marker is by
default a newline (line feed).

For multi-line requests, it is possible to change the end-of-request marker.
Syntax: :samp:`console = require('console'); console.delimiter({string-literal})`.
The string-literal must be a value in single quotes. Effect: string becomes
end-of-request delimiter, so newline alone is not treated as end of request.
To go back to normal mode: :samp:`console.delimiter(''){string-literal}`. Example:

.. code-block:: lua_tarantool

    console = require('console'); console.delimiter('!')
    function f ()
      statement_1 = 'a'
      statement_2 = 'b'
    end!
    console.delimiter('')!

For a condensed Backus-Naur Form [BNF] description of the suggested form
of client requests, see http://tarantool.org/doc/box-protocol.html.

In *interactive* mode, one types requests and gets results. Typically the
requests are typed in by the user following prompts. Here is an example of
an interactive-mode tarantool client session:

| :codenormal:`$` :codebold:`tarantool`
| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| :codenormal:`[ tarantool will display an introductory message`
| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| :codenormal:`including version number here ]`
| :codenormal:`tarantool>` :codebold:`box.cfg{listen=3301}`
| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| :codenormal:`[ tarantool will display configuration information`
| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| :codenormal:`here ]`
| :codenormal:`tarantool>` :codebold:`s = box.schema.space.create('tester')`
| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| |nbsp| :codenormal:`[ tarantool may display an in-progress message here ]`
| :codenormal:`---`
| :codenormal:`...`
| :codenormal:`tarantool>` :codebold:`s:create_index('primary', {type = 'hash', parts = {1, 'NUM'}})`
| :codenormal:`---`
| :codenormal:`...`
| :codenormal:`tarantool>` :codebold:`box.space.tester:insert{1,'My first tuple'}`
| :codenormal:`---`
| :codenormal:`- [1, 'My first tuple']`
| :codenormal:`...`
| :codenormal:`tarantool>` :codebold:`box.space.tester:select(1)`
| :codenormal:`---`
| :codenormal:`- - [1, 'My first tuple']`
| :codenormal:`...`
| :codenormal:`tarantool>` :codebold:`box.space.tester:drop()`
| :codenormal:`---`
| :codenormal:`...`
| :codenormal:`tarantool>` :codebold:`os.exit()`
| :codenormal:`2014-04-30 10:28:00.886 [20436] main/101/spawner I> Exiting: master shutdown`
| :codenormal:`$`

Explanatory notes about what tarantool displayed in the above example:

* Many requests return typed objects. In the case of "``box.cfg{listen=3301}``",
  this result is displayed on the screen. If the request had assigned the result
  to a variable, for example "``c = box.cfg{listen=3301}``", then the result
  would not have been displayed on the screen.
* A display of an object always begins with "``---``" and ends with "``...``".
* The insert request returns an object of type = tuple, so the object display line begins with a single dash ('``-``'). However, the select request returns an object of type = table of tuples, so the object display line begins with two dashes ('``- -``').

=====================================================================
                        Utility ``tarantoolctl``
=====================================================================

.. program:: tarantoolctl

With ``tarantoolctl`` one can say: "start an instance of the Tarantool server
which runs a single user-written Lua program, allocating disk resources
specifically for that program, via a standardized deployment method."
If Tarantool was downloaded from source, then the script is in
:file:`[tarantool]/extra/dist/tarantoolctl`. If Tarantool was installed with Debian or
Red Hat installation packages, the script is renamed :program:`tarantoolctl`
and is in :file:`/usr/bin/tarantoolctl`. The script handles such things as:
starting, stopping, rotating logs, logging in to the application's console,
and checking status.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            configuring for tarantoolctl
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The :program:`tarantoolctl` script will read a configuration file named
:file:`~/.config/tarantool/default`, or 
:file:`/etc/sysconfig/tarantool`, or :file:`/etc/default/tarantool`. Most
of the settings are similar to the settings used by ``box.cfg{...};``
however, tarantoolctl adjusts some of them by adding an application name.
A copy of :file:`/etc/sysconfig/tarantool`, with defaults for all settings,
would look like this:

.. code-block:: lua

    default_cfg = {
        pid_file   = "/var/run/tarantool",
        wal_dir    = "/var/lib/tarantool",
        snap_dir   = "/var/lib/tarantool",
        sophia_dir = "/var/lib/tarantool",
        logger     = "/var/log/tarantool",
        username   = "tarantool",
    }
    instance_dir = "/etc/tarantool/instances.enabled"

The settings in the above script are:

``pid_file``
    The directory for the pid file and control-socket file. The
    script will add ":samp:`/{instance-name}`" to the directory name.

``wal_dir``
    The directory for the write-ahead :file:`*.xlog` files. The
    script will add ":samp:`/{instance-name}`" to the directory-name.

``snap_dir``
    The directory for the snapshot :file:`*.snap` files. The script
    will add ":samp:`/{instance-name}`" to the directory-name.

``sophia_dir``
    The directory for the sophia-storage-engine files. The script
    will add ":samp:`/sophia/{instance-name}`" to the directory-name.

``logger``
    The place where the application log will go. The script will
    add ":samp:`/{instance-name}.log`" to the name.

``username``
    the user that runs the tarantool server. This is the operating-system
    user name rather than the Tarantool-client user name.

``instance_dir``
    the directory where all applications for this host are stored. The user
    who writes an application for :program:`tarantoolctl` must put the
    application's source code in this directory, or a symbolic link. For
    examples in this section the application name my_app will be used, and
    its source will have to be in :samp:`{instance_dir}/my_app.lua`.


~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            commands for tarantoolctl
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The command format is :samp:`tarantoolctl {operation} {application_name}`, where
operation is one of: start, stop, enter, logrotate, status, reload. Thus ...

| :codenormal:`tarantoolctl start my_app            -- starts application my_app`
| :codenormal:`tarantoolctl stop my_app             -- stops my_app`
| :codenormal:`tarantoolctl enter my_app            -- show my_app's admin console, if it has one`
| :codenormal:`tarantoolctl logrotate my_app        -- rotate my_app's log files (make new, remove old)`
| :codenormal:`tarantoolctl status my_app           -- check my_app's status`
| :codenormal:`tarantoolctl reload my_app file_name -- execute code from file_name as an instance of my_app`

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     typical code snippets for tarantoolctl
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

A user can check whether my_app is running with these lines:

.. code-block:: bash

    if tarantoolctl status my_app; then
    ...
    fi

A user can initiate, for boot time, an init.d set of instructions:

.. code-block:: bash

    for (each file mentioned in the instance_dir directory):
        tarantoolctl start `basename $ file .lua`

A user can set up a further configuration file for log rotation, like this:

.. code-block:: lua

    /path/to/tarantool/*.log {
        daily
        size 512k
        missingok
        rotate 10
        compress
        delaycompress
        create 0640 tarantool adm
        postrotate
            /path/to/tarantoolctl logrotate `basename $ 1 .log`
        endscript
    }

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
      A detailed example for tarantoolctl
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The example's objective is: make a temporary directory where tarantoolctl
can start a long-running application and monitor it.

The assumptions are: the root password is known, the computer is only being used
for tests, the Tarantool server is ready to run but is not currently running,
and there currently is no directory named :file:`tarantool_test`.

Create a directory named /tarantool_test:


| :codebold:`$ sudo mkdir /tarantool_test`

Copy tarantoolctl to /tarantool_test. If you made a source
download to ~/tarantool-master, then

| :codebold:`$ sudo cp ~/tarantool-master/extra/dist/tarantoolctl /tarantool_test/tarantoolctl`

If the file was named tarantoolctl and placed on :file:`/usr/bin/tarantoolctl`, then

| :codebold:`$ sudo cp /usr/bin/tarantoolctl /tarantool_test/tarantoolctl`

Check and possibly change the first line of :file:`code/tarantool_test/tarantoolctl`.
Initially it says

| :codenormal:`#!/usr/bin/env tarantool`

If that is not correct, edit tarantoolctl and change the line. For example,
if the Tarantool server is actually on :file:`/home/user/tarantool-master/src/tarantool`,
change the line to

| :codebold:`#!/usr/bin/env /home/user/tarantool-master/src/tarantool`

Save a copy of :file:`/etc/sysconfig/tarantool`, if it exists.

Edit /etc/sysconfig/tarantool. It might be necessary to say sudo mkdir /etc/sysconfig first. Let the new file contents be:

.. code-block:: lua

    default_cfg = {
        pid_file = "/tarantool_test/my_app.pid",
        wal_dir = "/tarantool_test",
        snap_dir = "/tarantool_test",
        sophia_dir = "/tarantool_test",
        logger = "/tarantool_test/log",
        username = "tarantool",
    }
    instance_dir = "/tarantool_test"

Make the my_app application file, that is, :file:`/tarantool_test/my_app.lua`. Let the file contents be:

.. code-block:: lua

    box.cfg{listen = 3301}
    box.schema.user.passwd('Gx5!')
    box.schema.user.grant('guest','read,write,execute','universe')
    fiber = require('fiber')
    box.schema.space.create('tester')
    box.space.tester:create_index('primary',{})
    i = 0
    while 0 == 0 do
        fiber.sleep(5)
        i = i + 1
        print('insert ' .. i)
        box.space.tester:insert{i, 'my_app tuple'}
    end

Tell tarantoolctl to start the application ...

| :codebold:`$ cd /tarantool_test`
| :codebold:`$ sudo ./tarantoolctl start my_app`

... expect to see messages indicating that the instance has started. Then ...

| :codebold:`$ ls -l /tarantool_test/my_app`

... expect to see the .snap file, .xlog file, and sophia directory. Then ...

| :codebold:`$ less /tarantool_test/log/my_app.log`

... expect to see the contents of my_app's log, including error messages, if any. Then ...

| :codebold:`$ cd /tarantool_test`
| :codenormal:`#assume that 'tarantool' invokes the tarantool server`
| :codebold:`$ sudo tarantool`
| :codebold:`$ box.cfg{}`
| :codebold:`$ console = require('console')`
| :codebold:`$ console.connect('localhost:3301')`
| :codebold:`$ box.space.tester:select({0},{iterator='GE'})`

... expect to see several tuples that my_app has created.

Stop. The only clean way to stop my_app is with tarantoolctl, thus:

| :codebold:`$ sudo ./tarantoolctl stop my_app`

Clean up. Restore the original contents of :file:`/etc/sysconfig/tarantool`, and ...

| :codebold:`$ cd /`
| :codebold:`$ sudo rm -R tarantool_test`

=====================================================================
            System-specific administration notes
=====================================================================

This section will contain information about issue or features which exist
on some platforms but not others - for example, on certain versions of a
particular Linux distribution.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Administrating with Debian GNU/Linux and Ubuntu
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Setting up an instance:

| :codebold:`$ ln -s /etc/tarantool/instances.available/instance-name.cfg /etc/tarantool/instances.enabled/`

Starting all instances:

| :codebold:`$ service tarantool start`

Stopping all instances:

| :codebold:`$ service tarantool stop`

Starting/stopping one instance:

| :codebold:`$ service tarantool-instance-name start/stop`


~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                 Fedora, RHEL, CentOS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

There are no known permanent issues. For transient issues, go to
http://github.com/tarantool/tarantool/issues and enter "RHEL" or
"CentOS" or "Fedora" or "Red Hat" in the search box.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                       FreeBSD
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

There are no known permanent issues. For transient issues, go to
http://github.com/tarantool/tarantool/issues and enter "FreeBSD"
in the search box.

~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
                       Mac OS X
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

There are no known permanent issues. For transient issues, go to
http://github.com/tarantool/tarantool/issues and enter "OS X" in
the search box.
