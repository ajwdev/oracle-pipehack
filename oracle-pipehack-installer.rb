#!/usr/bin/env ruby

# Copyright (c) 2012, Intoximeters, Inc
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the <organization> nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL Intoximeters, Inc BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.



# This script is a wrapper around the Oracle Universal Installer (OUI) so 
# that we can install Oracle 11g synchronously in the foreground. The OUI
# is a Java application/wizard that uses Swing (gross). It has support for 
# response files for automated installations and a "-silent" flag. However
# despite both of those features the installer *still* requires an X server.
# Furthermore the OUI forks into another installer which backgrounds itself 
# because of its use of Swing. This script wraps the installer so it gets 
# installed in the foreground and uses a pipe to detect when the installer 
# has completed. This is achieved by doing the following:
#
#   - We first fork and exec an instance of Xvfb on X11 display ":1". This is
#     so that we can run the installer without it complaining about a missing X
#     server.
#
#   - Next, we create a pipe closing the write side in the parent and the read
#     side in the child. In the child we exec "su" specifying that we should 
#     become the Oracle user and run the OUI installer. The OUI will then fork 
#     again into another installer process (the grandchild). The tree looks 
#     something like this:
#     
#     pipehack-install
#       \_ Xvfb process
#       \_ OUI Installer (will disappear once child is forked)
#           \_ OUI Installer (grandchild)
#     
#   - Because the OUI does not perform any file descriptor cleanup our pipe
#     still exists in the parent and the grandchild. In the parent we perform a
#     read against the pipe which will block until 1) data is written to the 
#     pipe or 2) the pipe is closed. Condition 1 should never happen and thus
#     this call will block until the installer has completed and grandchild
#     ends. If condition 1 *does* happen we have some bigger issues and the 
#     technique used in this script will no longer work for us.
#
#   - Finally, when the grandchild process ends we then perform our post install
#     scripts. The OUI does another stupid thing when you use the "-silent"
#     argument and will have its post install scripts re-open stdout to a log
#     file. This makes zero sense when you have to run scripts manually anyhow.
#     The fix is fortunately simple. We simply change one of the variables in a
#     shell script from "1" to "-1" and we no longer will have a broken stdout.

require 'getoptlong'

def comment_or_whitespace?(str)
  # Get the easy ones out of the way first
  if str.start_with? "#" or str.start_with? "\n"
    return true
  end

  # Now we're going to check for blank lines with spaces
  # else it's a valid line 
  str.strip == ""
end

def run_install(response_file, oracle_installer, xdisplay)
  # First, lets start Xvfb on display :1
  # This is required for the awesomely dumb OUI that despite running in silent
  # mode still uses Swing and thus still requires an X11 server
  xvfb_pid = fork

  if xvfb_pid.nil?
    # We're in the child process
    # Close any unneeded file descriptors that may have been created by Ruby
    (5..1024).each do |i|
      begin
        fd = IO.for_fd i
        fd.close
      rescue Errno::EBADF
       # We dont actually care if we hit this exception since it just means the
       # file descriptor was not allocated and does not need closed
      end
    end

    # Reopen stdin, stdout, and stderr
    $stdin.reopen "/dev/null"
    $stdout.reopen "/dev/null"
    $stderr.reopen "/dev/null"

    exec "/usr/bin/Xvfb", xdisplay
  else
    # In parent process
    config = parse_response_file(response_file)
    rd, wr = IO.pipe

    if fork
      # We're still in the parent process
      wr.close

      # We will block on this read call until the file descriptor is closed.
      # In our case, the OUI does not clean up any file descriptors after 
      # it forks so this particular file descriptor wont close until the 
      # installer is done. I.E we block here until the installer completes
      rd.read
      
      # We dont need this anymore so lets not leak FDs
      rd.close
      
      # Lets check if ORACLE_HOME exists. If it doesnt we make the 
      # (bad) assumption that the install did not complete
      begin
        if File.exist? config["ORACLE_HOME"]
          # Run our post scripts that must be executed as root
          system "/bin/bash", "#{config["INVENTORY_LOCATION"]}/orainstRoot.sh"

          # If SILENT=1 in the following script, stdout will be redirected to a 
          # log file. We dont want that nor does it really make sense. Change 
          # the value of that variable and execute the final script
          system "/bin/sed", "-i.bak", "'s/SILENT=1/SILENT=-1/'", "#{config["ORACLE_HOME"]}/install/utl/rootmacro.sh"
          system "/bin/bash", "#{config["ORACLE_HOME"]}/root.sh"
        else
          raise "Oracle Universal Installer terminated"
        end
      ensure
        # Finally, lets kill our Xvfb process and ensure all children are dead
        Process.kill("TERM", xvfb_pid)
        Process.wait
      end
    else
      # We're in the child process
      rd.close

      # Set our DISPLAY variable to use the Xvfb xserver
      ENV['DISPLAY'] = xdisplay
      
      # Change to the Oracle user and run the installer
      exec "/bin/su", "-", "oracle", "-c", "#{oracle_installer}/runInstaller", "-silent", "-responseFile", response_file
    end
  end
end

def parse_response_file_data(value)
  if ! value.nil?
    case value.downcase.strip
    when "true"
      value = true
    when "false"
      value = false
    else
      value.strip!
    end
  end

  value
end

def parse_response_file(response_file_path)
  config = Hash.new
  
  File.open(response_file_path).each_line do |line|
    next if comment_or_whitespace? line

    key, value = line.split(/\s*=\s*/)
    config[key] = parse_response_file_data(value)
  end

  config
end


if __FILE__ == $0
  # Make sure we're root
  if Process.uid != 0
    abort "ERROR: Please re-run script as 'root'"
  end

  opts = GetoptLong.new(
    ['--help', '-h', GetoptLong::NO_ARGUMENT],
    ['--xdisplay', '-x', GetoptLong::REQUIRED_ARGUMENT],
    ['--response-file', '-r', GetoptLong::REQUIRED_ARGUMENT],
    ['--oracle-installer', '-i', GetoptLong::REQUIRED_ARGUMENT]
  )

  response_file = nil
  oracle_installer = nil
  xdisplay = ":1"
  opts.each do |opt, arg|
    case opt
      when '--help'
        puts "#{$0} <OPTIONS>

--help, -h:
  show help

--oracle-installer path, -i path:
  Path to the extracted Oracle installation

--response-file file, -r file:
  Path to OUI response file. It is *not* required 
  to be an absolute path like the OUI requires

--xdisplay [display], -x [display]:
  Start Xvfb on this X11 display. Default is :1

"
        exit
      when '--oracle-installer'
        oracle_installer = arg
      when '--response-file'
        response_file = arg
      when '--xdisplay'
        xdisplay = arg
    end
  end

  # OUI requires an absolute path because it's stupid. Sigh ....
  response_file = File.expand_path(response_file)

  # All arguments were passed in. Lets ensure our files exist
  if ! File.exist? response_file 
    abort "ERROR: Could not find response file"
  end

  if ! File.exist? oracle_installer
    abort "ERROR: Could not find OUI installer directory"
  end

  run_install(response_file, oracle_installer, xdisplay)
end

