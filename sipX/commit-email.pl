#!/usr/bin/env perl

# ====================================================================
# commit-email.pl: send a commit email for commit REVISION in
# repository REPOS to some email addresses.
#
# For usage, see the usage subroutine or run the script with no
# command line arguments.
#
# Copyright (C) 2004 SIPfoundry Inc.
# Licensed by SIPfoundry under the LGPL license.
#
# Copyright (C) 2004 Pingtel Corp.
# Licensed to SIPfoundry under a Contributor Agreement.
#
# Modified by ComputerTalk to send email to committer
#
# Adapted from the commit-email.pl in the subversion distribution,
# which was
# Copyright (c) 2000-2004 CollabNet.  All rights reserved.
#
# This software is licensed as described in the file COPYING, which
# you should have received as part of this distribution.  The terms
# are also available at http://subversion.tigris.org/license-1.html.
# If newer versions of this license are posted there, you may use a
# newer version instead, at your option.
#
# This software consists of voluntary contributions made by many
# individuals.  For exact contribution history, see the revision
# history and logs, available at http://subversion.tigris.org/.
# ====================================================================

require 5.6.0;  #  minimum Perl version for "warnings" module
use warnings;
use strict;
use Carp;
use Mail::Sender;
use HTML::Stream qw(html_escape);
#use HTTPD::RealmManager;

################################################################
# Configuration section.
################################################################

# Svnlook path.
my $svnlook = "/usr/bin/svnlook";

# Default from address
my $from_address = 'svn@sipez.com';

# Default project name
my $project = 'sipX';

# Default log file name
my $log = '';

# Default Reply-To address
my $reply_to = 'sipx-dev@list.sipfoundry.org';

# Default Committer Email Domain
my $email_domain = 'sipez.com';

# URL base for ViewCVS
my $viewsvnbase = 'http://sipxsvn.sipez.com/viewvc/';

# Default subject line prefix (note the blank)
#   this will be followed by the project name and new rev number
my $prefix   = '[svn-commit] ';

# Default Keywords header prefix
#   this will be sent in a Keywords header line with the project name appended
#   this is useful for Mailman Topics and other filters
my $keywords = 'SVN-COMMIT-';

# Switch that controls whether or not the commiter name is appended to the Subject line
my $show_committer=1; # 1=show commiter 0=omit commiter 

# Diff format switch for viewcvs
my $diff_format = 'l';

# Realm configuration file
#my $RealmConfig = '/home/www/etc/access_control/realms.conf';
#my $Realm = 'SIPfoundry';

################################################################
### End of configuration variables
################################################################

# Since the path to svnlook depends upon the local installation
# preferences, check that the required programs exist to insure that
# the administrator has set up the script properly.
{
  my $ok = 1;
  foreach my $program ($svnlook)
    {
      if (-e $program)
        {
          unless (-x $program)
            {
              warn "$0: required program `$program' is not executable, ",
                   "edit $0.\n";
              $ok = 0;
            }
        }
      else
        {
          warn "$0: required program `$program' does not exist, edit $0.\n";
          $ok = 0;
        }
    }
  exit 1 unless $ok;
}


######################################################################
# Initial setup/command-line handling.
use Getopt::Long;

GetOptions( 'project=s'      => \$project,
            'from_address:s' => \$from_address,
            'reply_to:s'     => \$reply_to,
            'keywords:s'     => \$keywords,
            'prefix:s'       => \$prefix,
            'show-committer!'=> \$show_committer,
            'diff-format:s'  => \$diff_format,
            'log:s'          => \$log,
	    );

my ( $repos, $rev, @email_addresses ) = @ARGV;

# If the revision number is undefined, then there were not enough
# command line arguments.
&usage("$0: too few arguments.") unless defined $rev;

# Check the validity of the command line arguments.  Check that the
# revision is an integer greater than 0 and that the repository
# directory exists.
unless ($rev =~ /^\d+/ and $rev > 0)
  {
    &usage("$0: revision number `$rev' must be an integer > 0.");
  }
unless (-e $repos)
  {
    &usage("$0: repos directory `$repos' does not exist.");
  }
unless (-d _)
  {
    &usage("$0: repos directory `$repos' is not a directory.");
  }

my $prev = $rev - 1;

######################################################################
# Harvest data using svnlook.

# Get the author, date, and log from svnlook.
my @svnlooklines = &read_from_process($svnlook, 'info', $repos, '-r', $rev);
my $author = shift @svnlooklines;
my $date = shift @svnlooklines;
shift @svnlooklines;
#push(@email_addresses, "$author\@$email_domain");

my (@log, $firstLogLine);
foreach ( @svnlooklines )
{
    if ( ! $firstLogLine && m/\S/ ) # first non-blank log line
    {
        $firstLogLine = $_;
    }
    push @log, "$_\n";
}

# Look up the users full name
#my $userdb = HTTPD::RealmManager->open(-config_file=>$RealmConfig,
#                                       -realm=>$Realm,
#                                       -writable=>0
#                                       );
#my $author_real = $userdb->get_fields(-user=>$author)->{'name'};

# Figure out what directories have changed using svnlook.
my @dirschanged = &read_from_process($svnlook, 'dirs-changed', $repos,
                                     '-r', $rev);

# Lose the trailing slash in the directory names if one exists, except
# in the case of '/'.
my $rootchanged = 0;
for (my $i=0; $i<@dirschanged; ++$i)
  {
    if ($dirschanged[$i] eq '/')
      {
        $rootchanged = 1;
      }
    else
      {
        $dirschanged[$i] =~ s#^(.+)[/\\]$#$1#;
      }
  }

# Figure out what files have changed using svnlook.
@svnlooklines = &read_from_process($svnlook, 'changed', $repos, '-r', $rev);

# Parse the changed nodes.
my @adds;
my @dels;
my @mods;
foreach my $line (@svnlooklines)
  {
    my $path = '';
    my $code = '';

    # Split the line up into the modification code and path, ignoring
    # property modifications.
    if ($line =~ /^(.).  (.*)$/)
      {
        $code = $1;
        $path = $2;
      }

    if ($code eq 'A')
      {
        push(@adds, $path);
      }
    elsif ($code eq 'D')
      {
        push(@dels, $path);
      }
    else
      {
        push(@mods, $path);
      }
  }


######################################################################
# Modified directory name collapsing.

# Collapse the list of changed directories only if the root directory
# was not modified, because otherwise everything is under root and
# there's no point in collapsing the directories, and only if more
# than one directory was modified.
my $commondir = '';
if (!$rootchanged and @dirschanged > 1)
  {
    my $firstline    = shift @dirschanged;
    my @commonpieces = split('/', $firstline);
    foreach my $line (@dirschanged)
      {
        my @pieces = split('/', $line);
        my $i = 0;
        while ($i < @pieces and $i < @commonpieces)
          {
            if ($pieces[$i] ne $commonpieces[$i])
              {
                splice(@commonpieces, $i, @commonpieces - $i);
                last;
              }
            $i++;
          }
      }
    unshift(@dirschanged, $firstline);

    if (@commonpieces)
      {
        $commondir = join('/', @commonpieces);
        my @new_dirschanged;
        foreach my $dir (@dirschanged)
          {
            if ($dir eq $commondir)
              {
                $dir = '.';
              }
            else
              {
                $dir =~ s#^$commondir/##;
              }
            push(@new_dirschanged, $dir);
          }
        @dirschanged = @new_dirschanged;
      }
  }
my $dirlist = join(' ', @dirschanged);

######################################################################
# Assembly of log message.

# Put together the parts of the log message.
my $arglist;
my ( @htmlmsg, @textmsg );

push(@htmlmsg, "<html><body>\n<table>\n");
push(@htmlmsg, "<tr><th>Project</th><td>$project</td></tr>\n");
push(@htmlmsg, "<tr><th>New Revision</th><td><a href='$viewsvnbase$project?view=rev&amp;rev=$rev'>$rev</a></td></tr>\n");
#push(@htmlmsg, "<tr><th>Committer</th><td>$author ($author_real)</td></tr>\n");
push(@htmlmsg, "<tr><th>Committer</th><td>$author</td></tr>\n");
push(@htmlmsg, "<tr><th>Date</th><td>$date</td></tr>\n");
push(@htmlmsg, "</table>\n");
push(@htmlmsg, "<h2>Log</h2>\n<pre>\n\n");
push(@htmlmsg, html_escape("@log"));
push(@htmlmsg, "\n\n</pre>\n");

push(@textmsg, "\n");
push(@textmsg, "Project:            $project\n");
push(@textmsg, "New Revision:       $rev <$viewsvnbase$project?view=rev&rev=$rev>\n");
#push(@textmsg, "Committer:          $author ($author_real)\n");
push(@textmsg, "Committer:          $author\n");
push(@textmsg, "Date:               $date\n");
push(@textmsg, "\n");
push(@textmsg, "Log:\n\n");
push(@textmsg, @log);
push(@textmsg, "\n\n");


if (@adds)
  {
    @adds = sort @adds;

    push(@htmlmsg, "<h2>Added:</h2><ul>\n");
    push(@htmlmsg, map { "   <li><a href='$viewsvnbase$project/$_?rev=$rev'>\n$_\n</a></li>\n" } @adds);
    push(@htmlmsg, "</ul>\n");

    push(@textmsg, "Added:\n");
    push(@textmsg, map { "     $_\n" } @adds);
    push(@textmsg, "\n");
  }
if (@dels)
  {
    @dels = sort @dels;

    push(@htmlmsg, "<h2>Removed:</h2><p>(links are to last version)</p><ul>\n");
    push(@htmlmsg, map { "   <li><a href='$viewsvnbase$project/$_?rev=$prev'>\n$_\n</a></li>\n" } @dels);
    push(@htmlmsg, "</ul>\n");

    push(@textmsg, "Removed:\n");
    push(@textmsg, map { "     $_\n" } @dels);
    push(@textmsg, "\n");

  }
if (@mods)
  {
    @mods = sort @mods;

    push(@htmlmsg, "<h2>Modified:</h2><ul>\n");
    push(@htmlmsg, map { "   <li><a href='$viewsvnbase$project/$_?r1=$prev\&r2=$rev\&diff_format=$diff_format'>\n$_\n</a></li>\n" } @mods);
    push(@htmlmsg, "</ul>\n");

    push(@textmsg, "Modified:\n");
    push(@textmsg, map { "     $_\n" } @mods);
    push(@textmsg, "\n");

  }
push(@htmlmsg, "</body></html>\n");

eval
{
    (new Mail::Sender)
        ->OpenMultipart({
            smtp=>'localhost',
            from=>$from_address,
            replyto=>$reply_to,
            to=>\@email_addresses,
            subject=>"$prefix$project $rev" . ($show_committer?" $author":"") . ": $firstLogLine",
            debug => '/tmp/commit-email.log',
            headers=>"Keywords: $keywords$project",
            multipart => 'mixed',
        })
        ->Part({ctype => 'multipart/alternative'})
        ->Part({ ctype => 'text/plain', disposition => 'NONE', msg => "@textmsg" })
        ->Part({ctype => 'text/html', disposition => 'NONE', msg => "@htmlmsg"})
        ->EndPart("multipart/alternative")
        ->Close();
} or print "Error sending mail: $Mail::Sender::Error\n";


# Dump the text output to logfile (if its name is not empty).
if ($log)
  {
    if (open(LOGFILE, ">> $log"))
      {
        print LOGFILE @htmlmsg;
        close LOGFILE
          or warn "$0: error in closing `$log' for appending: $!\n";
      }
    else
      {
        warn "$0: cannot open `$log' for appending: $!\n";
      }
  }


exit 0;

sub usage
{
    warn "@_\n" if @_;
    die "usage: \n",
    "  $0 REPOS REVNUM --project PROJECT [ OPTIONS ] email_addr ...\n",
    "OPTIONS are:\n",
    "  --from_address ADDR     Email address for 'From:'\n",
    "  --reply_to ADDR         Email address for 'Reply-To:'\n",
    "  --keywords KEYWORD      Keywords header prefix (project name is appended)\n",
    "  --prefix SUBJECT_PREFIX Subject header prefix (project name is appended)\n",
    "  --show-committer        Append the author name to the subject\n",
    "  --noshow-committer      Do not append the author name to the subject\n",
    "  --diff-format FORMAT    Diff format selector passed to viewCVS\n",
    "  --log LOGFILE           Append mail contents to this log file\n",
    "\n",
    "This script sends HTML email describing a commit to an svn repository.\n"
    }

# Start a child process safely without using /bin/sh.
sub safe_read_from_pipe
{
  unless (@_)
    {
      croak "$0: safe_read_from_pipe passed no arguments.\n";
    }

  my $pid = open(SAFE_READ, '-|');
  unless (defined $pid)
    {
      die "$0: cannot fork: $!\n";
    }
  unless ($pid)
    {
      open(STDERR, ">&STDOUT")
        or die "$0: cannot dup STDOUT: $!\n";
      exec(@_)
        or die "$0: cannot exec `@_': $!\n";
    }
  my @output;
  while (<SAFE_READ>)
    {
      s/[\r\n]+$//;
      push(@output, $_);
    }
  close(SAFE_READ);
  my $result = $?;
  my $exit   = $result >> 8;
  my $signal = $result & 127;
  my $cd     = $result & 128 ? "with core dump" : "";
  if ($signal or $cd)
    {
      warn "$0: pipe from `@_' failed $cd: exit=$exit signal=$signal\n";
    }
  if (wantarray)
    {
      return ($result, @output);
    }
  else
    {
      return $result;
    }
}

# Use safe_read_from_pipe to start a child process safely and return
# the output if it succeeded or an error message followed by the output
# if it failed.
sub read_from_process
{
  unless (@_)
    {
      croak "$0: read_from_process passed no arguments.\n";
    }
  my ($status, @output) = &safe_read_from_pipe(@_);
  if ($status)
    {
      return ("$0: `@_' failed with this output:", @output);
    }
  else
    {
      return @output;
    }
}
