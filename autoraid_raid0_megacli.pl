#!/usr/bin/perl -w
#
# chkconfig: 2345 30 98
# description: Perform RAID configuration
# processname: none

### BEGIN INIT INFO
# Provides:            autoraid
# Required-Start:      $all
# Required-Stop:
# X-UnitedLinux-Should-Start:
# X-UnitedLinux-Should-Stop:
# Default-Start:       2 3 5
# Default-Stop:        0 1 6
# Description:         Perform RAID configuration
### END INIT INFO

# to clear config on the controllers and start over:
# /opt/MegaRAID/MegaCli/MegaCli64 -CfgClr -aALL
# /opt/MegaRAID/MegaCli/MegaCli64 -CfgForeign -Clear -aALL
# 

use strict;
use Getopt::Std;
use POSIX;
use Term::ANSIColor qw(:constants);
use Switch;

$| = 1;
(my $prog = $0) =~ s|.*/(S\d{2,2})?||;

my $MegaCli='/opt/MegaRAID/MegaCli/MegaCli64';

switch ($ARGV[0]) {
  case 'start'  { print "Configuring Lustre Target LUNs...\n"; }
  case 'stop'   { exit; }
  case 'status' { print `$MegaCli -LDInfo -Lall -aALL -NoLog | egrep "Virtual|State"`; exit; }
  else          { print "Usage: $prog {start|stop|status}\n"; exit; }
}

my $media_error_thresh = 0;
my $predict_error_thresh = 0;
my $other_error_thresh = 0;
my $raid_set_size = 1; #include parity drives
my $expected_drive_count = 5;

my $expected_lun_count = int($expected_drive_count/$raid_set_size);

our($opt_h, $opt_d);
getopts('dh');

if ( $opt_h ) {
  print "Usage: $0 [-d]\n";
  print "       -d dryrun\n";
  exit;
}

my $adapters = 0;

# Get the number of RAID controllers we have
open (ADPCOUNT, "$MegaCli -adpCount -NoLog |")  
  || die "Failed: $!\n";

while (<ADPCOUNT>) {
        if ( m/Controller Count:\s*(\d+)/ ) {
                $adapters = $1;
                last;
        }
}
close ADPCOUNT;

for ( my $adp = 0; $adp < $adapters; $adp++ ) {
  my @drives;
  my $eid = '';
  my $did = '';
  my $media_err = 0;
  my $predict_err = 0;
  my $other_err = 0;
  my $err = 0;
  my $num_drives = 0;
  my $hotsparecount = 0;
  my $expectedsparecount = 0;
  my $done_ld = 0;

  open(MC,"$MegaCli -PDList -a$adp -NoLog |") 
    || die "Failed: $!\n";

  while ( my $line = <MC> ) {
    if ($line =~ /Enclosure Device ID:/) {
      $eid = ($line =~ m/\w+/g)[3];
    } elsif ($line =~ /Slot Number:/) {
      $did = ($line =~ m/\w+/g)[2];
      push (@drives, "$eid:$did");
    } elsif ($line =~ /Media Error Count:/) {
      $err = ($line =~ m/\w+/g)[3];
      if ($err > $media_error_thresh) {
        $media_err++;
      }
    } elsif ($line =~ /Other Error Count:/) {
      $err = ($line =~ m/\w+/g)[3];
      if ($err > $other_error_thresh) {
        $other_err++;
      }
    } elsif ($line =~ /Predictive Failure Count:/) {
      $err = ($line =~ m/\w+/g)[3];
      if ($err > $predict_error_thresh) {
        $predict_err++;
      }
    } elsif ( $line =~ m/Firmware state\s*:\s*(\w+)/ ) {
      $_ = $1;
      if ( /Hotspare/ ) {
        $hotsparecount++;
      }
    }
  }

  close(MC);

  $num_drives = @drives;
  print "Available drives: @drives\nPredict failed drives: $predict_err\nMedia error drives: $media_err\nOther error drives: $other_err\nTotal Drives: $num_drives\n";

  if (($predict_err > 0) || ($media_err > 0) || ($other_err > 0)) {
    print "Too many drive errors to continue, exiting... ";
    print RED, "[FAILED]\n", RESET;
    exit 1;
  }

  if ($num_drives != $expected_drive_count) {
    print "Found $num_drives drives, but expected $expected_drive_count, exiting... ";
    print RED, "[FAILED]\n", RESET;
    exit 1;
  }

  open (LDGETNUM, "$MegaCli -LdGetNum -a$adp -NoLog |") 
    || exitreport('UNKNOWN', "error: Could not execute $MegaCli -LdGetNum -a$adp -NoLog");
        
  my ($ldnum);
  while (<LDGETNUM>) {
    if ( m/Number of Virtual drives configured on adapter \d:\s*(\d+)/i ) {
      $ldnum = $1;
      last;
    }
  }
  close LDGETNUM;

  if ($ldnum == $expected_lun_count) {
    print "Already found expected number of logical disks on adaptor $adp, skipping ... ";
    print YELLOW,"[PASSED]\n", RESET;
    $done_ld = 1;
  }

  my $PDLIST = '';
  my $i = 0;
  my $j = 0;
  my $count = 0;
  for $i (0..(floor($num_drives/$raid_set_size)-1)) {
    for $j (1..$raid_set_size) {
       $PDLIST .= "$drives[$count],";
       $count++
    }

    chop $PDLIST;

    if (!$done_ld) {
      print "running: $MegaCli -CfgLdAdd -r0[$PDLIST] -a$adp -NoLog\n";
      if ( !$opt_d ) {
        system("$MegaCli", "-CfgLdAdd", "-r0[$PDLIST]", "-a$adp", "-NoLog");
        if ( $? == -1 ) {
          print "MegaCli failed: $! ";
          print RED, "[FAILED]\n", RESET;
        } else {
          print GREEN, "[OK]\n", RESET;
        }
      }
    }

    print "Setting LUN$i cache policies\n";
    system("$MegaCli", "-LDSetProp", "WB", "-L$i", "-a$adp", "-NoLog");
    system("$MegaCli", "-LDSetProp", "Cached", "-L$i", "-a$adp", "-NoLog");
    system("$MegaCli", "-LDSetProp", "ADRA", "-L$i", "-a$adp", "-NoLog");
    system("$MegaCli", "-LDSetProp", "-DisDskCache", "-L$i", "-a$adp", "-NoLog");

    $PDLIST = '';
  }

  $expectedsparecount = int($num_drives % $raid_set_size);

  if ($expectedsparecount == $hotsparecount) {
    print "Already found expected number of hot spares on adaptor $adp, skipping ... ";
    print YELLOW, "[PASSED]\n", RESET;
    next;
  }

  for my $k (1..$expectedsparecount) {
    $PDLIST .= "$drives[$count],";
    $count++;
  }

  chop $PDLIST;
  if ($PDLIST) {
    print "running: $MegaCli -PDHSP -Set -PhysDrv[$PDLIST] -a$adp -NoLog\n";
    if ( !$opt_d ) {
      system("$MegaCli", "-PDHSP", "-Set", "-PhysDrv[$PDLIST]", "-a$adp", "-NoLog");
      if ( $? == -1 ) {
        print "MegaCli failed: $! ";
        print RED, "[FAILED]\n", RESET;
      } else {
        print GREEN, "[OK]\n", RESET;
      }
    }
  }
}

print GREEN, "[OK]\n", RESET;
