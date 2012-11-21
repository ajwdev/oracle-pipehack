Oracle Pipehack
===============

This script is a wrapper around the Oracle Universal Installer (OUI) to install Oracle 11g synchronously in the foreground but also silently as well. More precisely, to work around the OUI's use of Swing. It was created so that we could reliably install Oracle 11g on our database servers via Chef. Its only been tested with Oracle 11g but *should* also work with 10g. 

Please see the script itself for further documentatin as it is heavily commented.


Prereqs
=======

You'll need the following succesfully use the script:

1. A copy of the Oracle 10/11g installation files

[http://www.oracle.com/technetwork/database/enterprise-edition/downloads/index.html]

2. A working "Response File" for your version of Oracle

[http://docs.oracle.com/cd/B28359_01/gateways.111/b31043/advance.htm]

3. A working copy of Ruby. The script was tested against versions 1.8.7 and 1.9.3

4. The "Xvfb" package. (On Redhat systems, 'yum install xorg-x11-server-Xvfb')


Usage
=====

First extract out your Oracle installation files and the find the 'runInstaller' file. The directory it is located in will be your "Oracle Installer Path", or the "-i" argument. Once you have that you should be able to do something along the lines of this:

    ./oracle-pipehack.rb -i /home/oracle/database -r /path/to/response/file.rsp

You can also optionally specify which X11 display Xvfb should use (the default is ":1") with the "-x" argument.


Submitting Changes
==================

Please create pull requests for any changes you would like to submit.
