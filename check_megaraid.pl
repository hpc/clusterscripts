#!/usr/bin/perl -w

use strict;
use Getopt::Std;
use POSIX qw(strftime);

our($opt_h, $opt_s, $opt_o, $opt_m, $opt_p, $opt_b, $opt_t, $opt_c);


getopts('bcths:o:p:m:');

if ( $opt_h ) {
	print "Usage: $0 [-s number] [-m number] [-o number]\n";
	print "       -b check Battery Back Up status\n";
	print "       -c check cache settings\n";
	print "       -s is how many hotspares are attached to the controller\n";
	print "       -m is the number of media errors to ignore\n";
	print "       -p is the predictive error count to ignore\n";
	print "       -o is the number of other disk errors to ignore\n";
        print "       -t print timestamps\n";
	exit;
}

my $megaclibin = '/opt/MegaRAID/MegaCli/MegaCli64';  # the full path to your MegaCli binary
my $megacli = "$megaclibin";      # how we actually call MegaCli
my $megapostopt = '-NoLog';            # additional options to call at the end of MegaCli arguments

my ($adapters);
my $hotspares = 0;
my $pdbad = 0;
my $pdcount = 0;
my $mediaerrors = 0;
my $mediaallow = 0;
my $prederrors = 0;
my $predallow = 0;
my $othererrors = 0;
my $otherallow = 0;
my $result = '';
my $status = 'OK';
my $checkbbu = 0;

sub max_state ($$) {
	my ($current, $compare) = @_;
	
	if (($compare eq 'CRITICAL') || ($current eq 'CRITICAL')) {
		return 'CRITICAL';
	} elsif ($compare eq 'OK') {
		return $current;
	} elsif ($compare eq 'WARNING') {
		return 'WARNING';
	} elsif (($compare eq 'UNKNOWN') && ($current eq 'OK')) {
		return 'UNKNOWN';
	} else {
		return $current;
	}
}

sub exitreport ($$) {
	my ($status, $message) = @_;

        if( $opt_t ) {
		print strftime("%a, %d %b %Y %H:%M:%S %z ", localtime(time()));	
	}

	if ( $pdcount == 0 ) {
		print "ERROR?: No drives found\n";
	}

	print "SERVERSTATUS=$status\n$message\n";
	if ( $status eq "OK" ) {
		exit 0;
	} else { 
		exit 1; 
	}
}


if ( $opt_s ) {
	$hotspares = $opt_s;
}
if ( $opt_m ) {
	$mediaallow = $opt_m;
}
if ( $opt_p ) {
	$predallow = $opt_p;
}
if ( $opt_o ) {
	$otherallow = $opt_o;
}
if ( $opt_b ) {
       $checkbbu = $opt_b;
}

# Some sanity checks that you actually have something where you think MegaCli is
(-e $megaclibin)
	|| exitreport('UNKNOWN',"error: $megaclibin does not exist");	

# Get the number of RAID controllers we have
open (ADPCOUNT, "$megacli -adpCount $megapostopt |")  
	|| exitreport('UNKNOWN',"error: Could not execute $megacli -adpCount $megapostopt");

while (<ADPCOUNT>) {
	if ( m/Controller Count:\s*(\d+)/ ) {
		$adapters = $1;
		last;
	}
}
close ADPCOUNT;

ADAPTER: for ( my $adp = 0; $adp < $adapters; $adp++ ) {
	my $hotsparecount = 0;
	# Get the Battery Back Up state for this adapter
	my ($bbustate);
	if ($checkbbu) {
		open (BBUGETSTATUS, "$megacli -AdpBbuCmd -GetBbuStatus -a$adp $megapostopt |")
			|| exitreport('UNKNOWN', "error: Could not execute $megacli -AdpBbuCmd -GetBbuStatus -a$adp $megapostopt");

		my ($bbucharging, $bbufullycharged, $bburelativecharge, $bbuexitcode);
		while (<BBUGETSTATUS>) {
			# Charging Status
			if ( m/Charging Status\s*:\s*(\w+)/i ) {
				$bbucharging = $1;
			} elsif ( m/Fully Charged\s*:\s*(\w+)/i ) {
				$bbufullycharged = $1;
			} elsif ( m/Relative State of Charge\s*:\s*(\w+)/i ) {
				$bburelativecharge = $1;
			} elsif ( m/Exit Code\s*:\s*(\w+)/i ) {
				$bbuexitcode = $1;
			}
		}
		close BBUGETSTATUS;

		# Determine the BBU state
		if ( $bbuexitcode ne '0x00' ) {
			$bbustate = 'NOT FOUND';
			$status = 'CRITICAL';
		} elsif ( $bbucharging ne 'None' ) {
			$bbustate = 'Charging(' . $bburelativecharge . '%)';
			$status = 'WARNING';
		} elsif ( $bbufullycharged ne 'Yes' ) {
			$bbustate = 'NotCharging(' . $bburelativecharge . '%)';
			$status = 'WARNING';
		} else {
			$bbustate = 'Charged(' . $bburelativecharge . '%)';
		}
	}

	# Get the number of logical drives on this adapter
	open (LDGETNUM, "$megacli -LdGetNum -a$adp $megapostopt |") 
		|| exitreport('UNKNOWN', "error: Could not execute $megacli -LdGetNum -a$adp $megapostopt");
	
	my ($ldnum);
	while (<LDGETNUM>) {
		if ( m/Number of Virtual drives configured on adapter \d:\s*(\d+)/i ) {
			$ldnum = $1;
			last;
		}
	}
	close LDGETNUM;
	
	LDISK: for ( my $ld = 0; $ld < $ldnum; $ld++ ) {
		# Get info on this particular logical drive
		open (LDINFO, "$megacli -LdInfo -L$ld -a$adp $megapostopt |") 
			|| exitreport('UNKNOWN', "error: Could not execute $megacli -LdInfo -L$ld -a$adp $megapostopt ");
			
		my $consistency_output = '';
		my ($size, $unit, $raidlevel, $ldpdcount, $state, $spandepth, $consistency_percent, $consistency_minutes, $ccache_policy, $dcache_policy);

		while (<LDINFO>) {
			if ( m/^Size\s*:\s*((\d+\.?\d*)\s*(MB|GB|TB))/ ) {
				$size = $2;
				$unit = $3;
				# Adjust MB to GB if that's what we got
				if ( $unit eq 'MB' ) {
					$size = sprintf( "%.0f", ($size / 1024) );
					$unit= 'GB';
				}
			} elsif ( m/State\s*:\s*(\w+)/ ) {
				$state = $1;
				if ( $state ne 'Optimal' ) {
					$status = 'CRITICAL';
				}
			} elsif ( m/Number Of Drives\s*(per span\s*)?:\s*(\d+)/ ) {
				$ldpdcount = $2;
			} elsif ( m/Span Depth\s*:\s*(\d+)/ ) {
				$spandepth = $1;
			} elsif ( m/RAID Level\s*: Primary-(\d)/ ) {
				$raidlevel = $1;
			} elsif ( m/\s+Check Consistency\s+:\s+Completed\s+(\d+)%,\s+Taken\s+(\d+)\s+min/ ) {
				$consistency_percent = $1;
				$consistency_minutes = $2;
			} elsif ( m/Current Cache Policy\s*:\s*([\w \,]+)/ ) {
				$ccache_policy = $1;
				if ( $ccache_policy ne 'WriteBack, ReadAdaptive, Cached, No Write Cache if Bad BBU' ) {
					if ( $opt_c ) {
						$status = 'WARNING-CACHE-POLICY';
					}
				}
			} elsif ( m/Disk Cache Policy\s*:\s*([\w \,\']+)/ ) {
				$dcache_policy = $1;
				if ( $dcache_policy ne 'Disabled' ) {
					if ( $opt_c ) {
						$status = 'WARNING-CACHE-POLICY';
					}
				}
			}
		}
		close LDINFO;

		# Report correct RAID-level and number of drives in case of Span configurations
		if ($ldpdcount && $spandepth > 1) {
			$ldpdcount = $ldpdcount * $spandepth;
			if ($raidlevel < 10) {
				$raidlevel = $raidlevel . "0";
			}
		}

		if ($consistency_percent) {
			$status = 'WARNING\n';
			$consistency_output = "CC ${consistency_percent}% ${consistency_minutes}m";
		}

		$result .= "Adp=$adp Ld=$ld RAID=RAID$raidlevel drives=$ldpdcount size=$size$unit state=$consistency_output$state\n";
		if ( $opt_c ) {
			$result .= "Adp=$adp Ld=$ld ControllerCache=\"$ccache_policy\" DiskCache=\"$dcache_policy\"\n";
		}
		
	} #LDISK
	close LDINFO;
	
	# Get info on physical disks for this adapter
	open (PDLIST, "$megacli -PdList  -a$adp $megapostopt |") 
		|| exitreport('UNKNOWN', "error: Could not execute $megacli -PdList -a$adp $megapostopt ");
	
	my ($slotnumber,$fwstate);
	PDISKS: while (<PDLIST>) {
		if ( m/Slot Number\s*:\s*(\d+)/ ) {
			$slotnumber = $1;
			$pdcount++;
		} elsif ( m/(\w+) Error Count\s*:\s*(\d+)/ ) {
			if ( $1 eq 'Media') {
				$mediaerrors += $2;
			} else {
				$othererrors += $2;
			}
		} elsif ( m/Predictive Failure Count\s*:\s*(\d+)/ ) {
			$prederrors += $1;
		} elsif ( m/Firmware state\s*:\s*(\w+)/ ) {
			$fwstate = $1;
			if ( $fwstate eq 'Hotspare' ) {
				$hotsparecount++;
			} elsif ( $fwstate eq 'Online' ) {
				# Do nothing
			} elsif ( $fwstate eq 'Unconfigured' ) {
				# A drive not in anything, or a non drive device
				$pdcount--;
			} elsif ( $slotnumber != 255 ) {
				$pdbad++;
				$status = 'CRITICAL';
			}
		}
	} #PDISKS
	close PDLIST;
	$result .= "Adp=$adp hotspare=$hotsparecount\n";
	$result .= "Adp=$adp BBU=$bbustate\n" if ($checkbbu);
}

$result .= "TotalDrives=$pdcount ";

# Any bad disks?
$result .= "BadDrives=$pdbad ";

my $errorcount = $mediaerrors + $prederrors + $othererrors;
# Were there any errors?
$result .= "errors=$errorcount ";
if ( $errorcount ) {
	if ( ( $mediaerrors > $mediaallow ) || 
	     ( $prederrors > $predallow )   || 
	     ( $othererrors > $otherallow ) ) {
		$status = max_state($status, 'WARNING');
	}
}

exitreport($status, $result);
