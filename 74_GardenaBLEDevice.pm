###############################################################################
#
#  (c) 2022 Copyright: ambiman
#  All rights reserved
#
#  This script is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  Version: 0.3
###############################################################################

package main;

use strict;
use warnings;
use POSIX;
use JSON::XS;
use DateTime;

my $version = '0.3';

my %GardenaBLEDevice_Models = (
	watercontrol => {
		'timestamp'							=> '98bd0b13-0b0e-421a-84e5-ddbf75dc6de4',
		'battery'							=> '98bd2a19-0b0e-421a-84e5-ddbf75dc6de4',
		'state'								=> '98bd0f11-0b0e-421a-84e5-ddbf75dc6de4',
		'one-time-watering-duration'		=> '98bd0f13-0b0e-421a-84e5-ddbf75dc6de4',
		'one-time-default-watering-time'	=> '98bd0f14-0b0e-421a-84e5-ddbf75dc6de4',
		'ctrlunitstate'						=> '98bd0f12-0b0e-421a-84e5-ddbf75dc6de4',
		'firmware_revision'					=> '00002a26-0000-1000-8000-00805f9b34fb', 	#Firmware Revision String
		'schedule1-wdays'					=> '98bd0c13-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule1-starttime'				=> '98bd0c11-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule1-duration'				=> '98bd0c12-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule2-wdays'					=> '98bd0c23-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule2-starttime'				=> '98bd0c21-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule2-duration'				=> '98bd0c22-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule3-wdays'					=> '98bd0c33-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule3-starttime'				=> '98bd0c31-0b0e-421a-84e5-ddbf75dc6de4',
		'schedule3-duration'				=> '98bd0c32-0b0e-421a-84e5-ddbf75dc6de4'
	}
);

my %GardenaBLEDevice_Set_Opts = (
	all => {
		'on' => undef,
		'resetGattCount' => undef
	},
	watercontrol => {
		'on-for-timer'	=> undef,
		'off'	=> undef,
		'default-watering-time'	=> undef,
		'synchronizeClock'	=> undef,
		'setSchedule1'	=> undef,
		'setSchedule2'	=> undef,
		'setSchedule3'	=> undef,
		'deleteSchedule1'	=> undef,
		'deleteSchedule2'	=> undef,
		'deleteSchedule3'	=> undef,
		'deleteAllSchedules'	=> undef
	}	
);

my %GardenaBLEDevice_Get_Opts = (
	all => {
		'stateRequest'	=> undef
	},
	watercontrol => {
		'remainingTime'	=> undef,
		'ctrlunitstate'	=> undef
	}
);

sub GardenaBLEDevice_Initialize($) {
    my ($hash) = @_;

	$hash->{SetFn}    = "GardenaBLEDevice_Set";
	$hash->{GetFn}    = "GardenaBLEDevice_Get";
	$hash->{DefFn}    = "GardenaBLEDevice_Define";
	$hash->{NotifyFn} = "GardenaBLEDevice_Notify";
	$hash->{UndefFn}  = "GardenaBLEDevice_Undef";
	$hash->{AttrFn}   = "GardenaBLEDevice_Attr";
	$hash->{AttrList} =
		"disable:1 "
		. "interval "
		. "default-on-time-fhem "
		. "btSecurityLevel:low,medium "
		. "sleepBetweenGATTCmds:1,2,3,4,5 "
		. "GATTtimeout "
		. "maxErrorCount "
		. "hciDevice:hci0,hci1,hci2 "
		. "blockingCallLoglevel:2,3,4,5 "
		. $readingFnAttributes;
}

# declare prototype
sub GardenaBLEDevice_ExecGatttool_Run($);

sub GardenaBLEDevice_Define($$) {

	my ( $hash, $def ) = @_;
	my @param = split('[ \t]+', $def );

	return "too few parameters: define <name> GardenaBLEDevice <BTMAC> <MODEL>" if ( @param != 4 );
	return "wrong input for model: choose one of " . join(' ', keys %GardenaBLEDevice_Models) if (@param >= 3) && (!defined(%GardenaBLEDevice_Models{$param[3]}));
	
	my $name = $param[0];
	my $mac  = $param[2];
	my $model = $param[3];

	$hash->{MODULE_VERSION}				= $version;
	$hash->{BTMAC}						= $mac;
	$hash->{INTERVAL}					= 300;
	$hash->{DEFAULT_ON_TIME_FHEM}		= 1800;
	$hash->{SLEEP_BETWEEN_GATT_CMDS}	= 1;
	$hash->{BTSECLEVEL}					= "medium";
	$hash->{GATTCOUNT}					= 0;
	$hash->{GATTTIMEOUT}				= 20;
	$hash->{MAXGATTQUEUE}				= 80;
	$hash->{MAXERRORCOUNT}				= 30;
	$hash->{ERRORCOUNT}					= 0;
	$hash->{MODEL}						= $model;
	$hash->{NOTIFYDEV}					= "global,$name";
	
	$attr{$name}{webCmd}				= "on:off";
	$attr{$name}{room}					= "GardenaBLE" if !defined($attr{$name}{room});
	
	$modules{GardenaBLEDevice}{defptr}{ $hash->{BTMAC} } = $hash;
	
	readingsSingleUpdate( $hash, "state", "initialized", 0 );
	
	# Set commands supported by every Gardena BLE device + model specific ones
	my %set_commands = (%{%GardenaBLEDevice_Set_Opts{all}}, %{%GardenaBLEDevice_Set_Opts{$model}});
	$hash->{helper}->{Set_CommandSet} = \%set_commands;
	
	# Get commands supported by every Gardena BLE device + model specific ones
	my %get_commands = (%{%GardenaBLEDevice_Get_Opts{all}}, %{%GardenaBLEDevice_Get_Opts{$model}});
	$hash->{helper}->{Get_CommandSet} = \%get_commands;
	
	my @jobs = ();
	
	#Array for pending GATT jobs
	$hash->{helper}{GT_QUEUE} = \@jobs;
	
	Log3 $name, 3, "GardenaBLEDevice ($name) - defined with BTMAC $hash->{BTMAC}";
	
	return undef;
}

sub GardenaBLEDevice_Undef($$) {

	my ( $hash, $arg ) = @_;

	my $mac  = $hash->{BTMAC};
	my $name = $hash->{NAME};

	RemoveInternalTimer($hash);
	BlockingKill( $hash->{helper}{RUNNING_PID} ) if ( defined( $hash->{helper}{RUNNING_PID} ) );

	#Todo: necessary ?
	delete ( $hash->{helper}{GT_QUEUE} ) if ( defined( $hash->{helper}{GT_QUEUE} ) );

	delete( $modules{GardenaBLEDevice}{defptr}{$mac} );
	
	Log3 $name, 3, "Sub GardenaBLEDevice_Undef ($name) - deleted device $name";
	
	return undef;
}

sub GardenaBLEDevice_Attr(@) {

	my ( $cmd, $name, $attrName, $attrVal ) = @_;
	my $hash = $defs{$name};
	
	Log3($name, 4,"GardenaBLEDevice_Attr ($name) - cmd: $cmd | attrName: $attrName | attrVal: $attrVal" );
	
	if ( $attrName eq "disable" ) {
	
		if ( $cmd eq "set" and $attrVal eq "1" ) {
			
			GardenaBLEDevice_Disable($hash);
		}
		elsif ( $cmd eq "del" ) {
			Log3 $name, 3, "GardenaBLEDevice ($name) - enabled";
			readingsSingleUpdate( $hash, "state", "pending", 1 );
		}
	}
	elsif ( $attrName eq "interval" ) {
		
		RemoveInternalTimer($hash);

		if ( $cmd eq "set" ) {
			if ( $attrVal < 30 ) {
				Log3($name, 3, "GardenaBLEDevice ($name) - interval too small, please use something >= 30 (sec), default is 300 (sec)");
				return "interval too small, please use something >= 30 (sec), default is 300 (sec)";
			}
			else {
				$hash->{INTERVAL} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set interval to $attrVal");
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{INTERVAL} = 300;
			Log3($name, 3,"GardenaBLEDevice ($name) - set interval to default value 300 (sec)");
		}
	}
	elsif ( $attrName eq "default-on-time-fhem" ) {
		
		if ( $cmd eq "set" ) {
			if ($attrVal >= 60 && $attrVal <= 28740)  {
				$hash->{DEFAULT_ON_TIME_FHEM} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set default-on-time-fhem to $attrVal");
			}
			else {
				Log3($name, 3, "GardenaBLEDevice ($name) - default-on-time-fhem invalid, please use something >= 60 (sec) and <= 28740 (sec), default is 1800 (sec)");
				return "default-on-time-fhem invalid, please use something >= 60 (sec) and <= 28740 (sec), default is 1800 (sec)";
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{DEFAULT_ON_TIME_FHEM} = 1800;
			Log3($name, 3,"GardenaBLEDevice ($name) - set default-on-time-fhem to default value 1800 (sec)");
		}
	}
	elsif ( $attrName eq "btSecurityLevel" ) {
		
		if ( $cmd eq "set" ) {
			
			if ($attrVal eq 'low' || $attrVal eq 'medium' ) {
				$hash->{BTSECLEVEL} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set btSecurityLevel to $attrVal");
			}
			else {
				Log3($name, 3, "GardenaBLEDevice ($name) - btSecurityLevel invalid, please use either low or medium.");
				return "btSecurityLevel invalid, please use either low or medium.)";
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{BTSECLEVEL} = "medium";
			Log3($name, 3,"GardenaBLEDevice ($name) - set btSecurityLevel to default value medium.");
		}
	}
	elsif ( $attrName eq "sleepBetweenGATTCmds" ) {
		
		if ( $cmd eq "set" ) {
			
			if ($attrVal > 0 && $attrVal <= 5 ) {
				$hash->{SLEEP_BETWEEN_GATT_CMDS} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set sleepBetweenGATTCmds to $attrVal");
			}
			else {
				Log3($name, 3, "GardenaBLEDevice ($name) - sleepBetweenGATTCmds invalid, please within the range 1-5 (sec)");
				return "sleepBetweenGATTCmds invalid, please within the range 1-5 (sec).";
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{SLEEP_BETWEEN_GATT_CMDS} = 1;
			Log3($name, 3,"GardenaBLEDevice ($name) - set sleepBetweenGATTCmds to default value 1 second.");
		}
	}
	elsif ( $attrName eq "maxErrorCount" ) {
		
		if ( $cmd eq "set" ) {
			
			if ($attrVal >= 5 && $attrVal <= 200 ) {
				$hash->{MAXERRORCOUNT} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set maxErrorCount to $attrVal");
			}
			else {
				Log3($name, 3, "GardenaBLEDevice ($name) - maxErrorCount invalid, please choose within the range of 5-200 attempts");
				return "maxErrorCount invalid, please choose within the range 5-200 attempts.";
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{MAXERRORCOUNT} = 30;
			Log3($name, 3,"GardenaBLEDevice ($name) - set maxErrorCount to default value of 30 attempts.");
		}
	}
	elsif ( $attrName eq "GATTtimeout" ) {
		
		if ( $cmd eq "set" ) {
			
			if ($attrVal >= 10 && $attrVal <= 60 ) {
				$hash->{GATTTIMEOUT} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set GATTtimeout to $attrVal");
			}
			else {
				Log3($name, 3, "GardenaBLEDevice ($name) - GATTtimeout invalid, please choose within the range of 10-60 seconds.");
				return "GATTtimeout invalid, please choose within the range 10-60 seconds.";
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{GATTTIMEOUT} = 20;
			Log3($name, 3,"GATTtimeout ($name) - set maxErrorCount to default value of 20 seconds.");
		}
	}
	return undef;
}

sub GardenaBLEDevice_Notify($$) {

	my ( $hash, $dev ) = @_;
	my $name = $hash->{NAME};

	my $devname = $dev->{NAME};
	my $devtype = $dev->{TYPE};
	my $events  = deviceEvents( $dev, 1 );
	
	Log3 $name, 5, "GardenaBLEDevice_Notify ($name) - devname: $devname | devtype: $devtype | events: @$events";

	return if ( !$events );

	#Trigger state request
	GardenaBLEDevice_stateRequestTimer($hash)
		if (
		(
			(
			grep /^DEFINED.$name$/,
			@{$events}
			or grep /^DELETEATTR.$name.disable$/,
			@{$events}
			or grep /^ATTR.$name.disable.0$/,
			@{$events}
			or grep /^DELETEATTR.$name.interval$/,
			@{$events}
			or grep /^DELETEATTR.$name.model$/,
			@{$events}
			or grep /^ATTR.$name.model.+/,
			@{$events}
			or grep /^ATTR.$name.interval.[0-9]+/,
			@{$events}
			)
		and $devname eq 'global'
		)
		or (
		(
			grep /^INITIALIZED$/,
			@{$events}
			or grep /^REREADCFG$/,
			@{$events}
			or grep /^MODIFIED.$name$/,
			@{$events}
		)
		and $devname eq 'global'
		)
		);

	return;
}

sub GardenaBLEDevice_Set($@) {

	my ( $hash, @param ) = @_;

	my ($name, $cmd, @args)  = @param;
	
	my $mod = 'write';
	my $model = $hash->{MODEL};
	
	my $supported_cmd=0;
	my $errorParseCmd=0;
	
	return 0 if ( IsDisabled($name) );
	
	foreach my $command (keys %{$hash->{helper}{Set_CommandSet}}) {
		
		$command=~s/:.*//;
		
		if(lc $command eq lc $cmd){
			$supported_cmd=1;
		}
	}
	
	return "Unknown argument $cmd, choose one of " . join(" ", keys %{$hash->{helper}{Set_CommandSet}}) if ($supported_cmd==0);
		
	if (lc $cmd eq 'on') {
		
		if ($hash->{helper}{$model}{onetimewaterhandle}) {

			readingsSingleUpdate( $hash, "state", "set_on", 1 );
	
			GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterhandle}, sprintf(uc(unpack("H*",pack("V*",$hash->{DEFAULT_ON_TIME_FHEM})))) );
			GardenaBLEDevice_stateRequest($hash);
			GardenaBLEDevice_getCharValue($hash, 'one-time-watering-duration');
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_on: onetimewaterhandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterhandle char value handle does not exist");
			
			return "Error: onetimewaterhandle char value handle does not exist.";
		}
	}
	elsif(lc $cmd eq 'off') {
		
		if ($hash->{helper}{$model}{onetimewaterhandle}) {
			
			readingsSingleUpdate( $hash, "state", "set_off", 1 );	
		 
			GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterhandle}, sprintf(uc(unpack("H*",pack("V*",0)))) );
			GardenaBLEDevice_stateRequest($hash);
			GardenaBLEDevice_getCharValue($hash, 'one-time-watering-duration');
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_off: onetimewaterhandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterhandle char value handle does not exist");
			
			return "Error: onetimewaterhandle char value handle does not exist.";
		}
	}
	elsif(lc $cmd eq 'on-for-timer') {
		
		if ($hash->{helper}{$model}{onetimewaterhandle}) {
			
			if (@args == 1) {
				
				my $value = $args[0];
			
				if ($value >= 60 && $value <= 28740) {
		
					readingsSingleUpdate( $hash, "state", "set_on-for-timer ".$value, 1 );

					GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterhandle}, sprintf(uc(unpack("H*",pack("V*",$value)))) );
					GardenaBLEDevice_stateRequest($hash);
					GardenaBLEDevice_getCharValue($hash, 'one-time-watering-duration');
				}
				else {
					$errorParseCmd = 1;
				}
			}
			else {
				$errorParseCmd = 1;
			}
			
			return "Use set <device> on-for-timer [range 60-28740]" if ($errorParseCmd == 1);
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_on-for-timer: onetimewaterhandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterhandle char value handle does not exist");
			
			return "Error: onetimewaterhandle char value handle does not exist.";
		}
	}
	elsif(lc $cmd eq 'default-watering-time') {
		
		if ($hash->{helper}{$model}{onetimewaterdeftimehandle}) {
			
			if (@args == 1) {
				
				my $value = $args[0];
	
				if ($value >= 60 && $value <= 28740) {
		
					readingsSingleUpdate( $hash, "state", "set_default-watering-time ".$value, 1 );

					GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterdeftimehandle}, sprintf(uc(unpack("H*",pack("V*",$value)))) );
					GardenaBLEDevice_stateRequest($hash);
					GardenaBLEDevice_getCharValue($hash,'one-time-default-watering-time');
				}
				else {
					$errorParseCmd = 1;
				}
			}
			else {
				$errorParseCmd = 1;
			}
			
			return "Use set <device> default-watering-time [range 60-28740]" if ($errorParseCmd == 1);
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set c";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterdeftimehandle char value handle does not exist");
			
			return "Error: onetimewaterdeftimehandle char value handle does not exist.";
		}
	}
	elsif(lc $cmd eq lc 'resetGattCount') {
		
		Log3 $name, 5, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set set GATTCOUNT to 0.";
		
		$hash->{GATTCOUNT}=0;
	}
	elsif(lc $cmd eq lc 'synchronizeClock') {
		
		#Get current timestamp
		my $currTime = DateTime->now(time_zone => 'local');
		
		#Get current TZ offset in seconds
		my $tz_offset =  $currTime->time_zone->offset_for_datetime($currTime);
		
		#The valve expects local time as unix timestamp, so we've to add the TZ offset
		my $dstTimestamp = time() + $tz_offset;

		GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{timestamphandle}, sprintf(uc(unpack("H*",pack("V*",$dstTimestamp)))) );
		GardenaBLEDevice_stateRequest($hash);
		GardenaBLEDevice_getCharValue($hash,'timestamp');

		Log3 $name, 3, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set synchronizeClock to ".localtime($dstTimestamp-$tz_offset)." ($dstTimestamp epoch time).";
	}
	elsif($cmd =~ m/^setSchedule([1-3]{1})$/i) {
		
		my $schedule = $1;
		
		if ($hash->{helper}{$model}{'schedule'.$1.'wdayshandle'} && $hash->{helper}{$model}{'schedule'.$1.'starttimehandle'} && $hash->{helper}{$model}{'schedule'.$1.'durationhandle'}) {
			
			if (@args == 3) {
			
				#Parse weekdays
				if ($args[0] =~ /^((?:mon|tue|wed|thu|fri|sat|sun)(?:,)?)(?1)*$/i) {
				
					my @weekdays = split(',',$args[0]);
				
					if (@weekdays > 0 && @weekdays <= 7){
					
						my $wday_value = 0;
					
						foreach (@weekdays) {
						
							$wday_value = $wday_value | (1 << 0) if (lc $_ eq 'mon');
							$wday_value = $wday_value | (1 << 1) if (lc $_ eq 'tue');
							$wday_value = $wday_value | (1 << 2) if (lc $_ eq 'wed');
							$wday_value = $wday_value | (1 << 3) if (lc $_ eq 'thu');
							$wday_value = $wday_value | (1 << 4) if (lc $_ eq 'fri');
							$wday_value = $wday_value | (1 << 5) if (lc $_ eq 'sat');
							$wday_value = $wday_value | (1 << 6) if (lc $_ eq 'sun');
						}
						#Parse start time
						if ($args[1] =~ /^([01]\d|2[0-3]):([0-5]\d):([0-5]\d)$/) {
						
							#Seconds after midnight
							my $starttime = $1 * 3600 + $2 * 60 + $3;
						
							#Parse watering duration
							if ($args[2] >= 5 && $args[2] <= 28740){
								
								#Writing schedule
								
								Log3 $name, 3, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set setSchedule". $schedule . " set weekdays to ".$args[0].".";
								GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{'schedule'.$schedule.'wdayshandle'}, sprintf(uc(unpack("H*",pack("c*",$wday_value)))) );
								
								Log3 $name, 3, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set setSchedule". $schedule . " set start time to ".$args[1].".";
								GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{'schedule'.$schedule.'starttimehandle'}, sprintf(uc(unpack("H*",pack("V*",$starttime)))) );
								
								Log3 $name, 3, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set setSchedule". $schedule . " set duration to ".$args[2].".";
								GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{'schedule'.$schedule.'durationhandle'}, sprintf(uc(unpack("H*",pack("V*",$args[2])))) );
								
								GardenaBLEDevice_stateRequestTimer($hash);
							}
							else {
								$errorParseCmd = 1;
							}
						}
						else {
							$errorParseCmd = 1;
						}
					}
					else {
						$errorParseCmd = 1;
					}
				}
				else {
					$errorParseCmd = 1;
				}
			}
			else {
				$errorParseCmd = 1;
			}
			
			return "Use set <device> setSchedule[1-3] [Mon,Tue,Wed,Thu,Fri,Sat,Sun] HH:MM:SS [range 5-28740]" if ($errorParseCmd == 1);
		}
		else {
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set setSchedule". $schedule ." one of the char value handles does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "one of the setSchedule char value handles does not exist");
			
			return "Error: one of the setSchedule char value handles does not exist.";
		}
	}
	elsif($cmd =~m/^(deleteAllSchedules|deleteSchedule([1-3]{1}))$/i) {
		
		my $handleMissing=0;
		my $start;
		my $end;
		
		#Distinguish between individual and all schedule clearing
		if ($2) {
			$start=$2;
			$end=$2;
		}
		else {
			$start=1;
			$end=3;
		}
		
		foreach my $schedule ($start .. $end) {
			
			if ($hash->{helper}{$model}{'schedule'.$schedule.'wdayshandle'} && $hash->{helper}{$model}{'schedule'.$schedule.'starttimehandle'} && $hash->{helper}{$model}{'schedule'.$schedule.'durationhandle'}) {
			
				#Writing schedules
				
				GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{'schedule'.$schedule.'wdayshandle'}, sprintf(uc(unpack("H*",pack("c*",0)))) );
			
				GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{'schedule'.$schedule.'starttimehandle'}, sprintf(uc(unpack("H*",pack("V*",0)))) );
			
				GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{'schedule'.$schedule.'durationhandle'}, sprintf(uc(unpack("H*",pack("V*",0)))) );
			
				Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set setSchedule schedule". $schedule . " cleared.";
				
				GardenaBLEDevice_stateRequestTimer($hash);
			}
			else {
				Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set deleteAllSchedules for schedule ".$schedule.": one of the char value handles does not exist.";
			
				GardenaBLEDevice_ProcessingErrors($hash, "one of the deleteAllSchedules for schedule ".$schedule." one of the char value handles does not exist");
			
				return "Error: one of the deleteAllSchedules for schedule ".$schedule." char value handles does not exist.";
			}
		}
	}
	else{
		return 0;
	}
}

sub GardenaBLEDevice_Get($$@) {

	my ( $hash, $name, @aa ) = @_;
	my ( $cmd, @args ) = @aa;

	my $mod = 'read';
	my $model = $hash->{MODEL};
	my $uuid;
	
	Log3 $name, 5, "GardenaBLEDevice_Get ($name) - cmd: ".$cmd;
	
	return "Unknown argument $cmd, choose one of ". join(" ", keys %{$hash->{helper}{Get_CommandSet}}) if (!exists($hash->{helper}{Get_CommandSet}{$cmd}));
	
	if ( $cmd eq 'stateRequest' ) {

		GardenaBLEDevice_stateRequest($hash);
	}
	elsif ( $cmd eq 'remainingTime' ) {

		GardenaBLEDevice_getCharValue($hash,'one-time-watering-duration');
	}
	elsif ( $cmd eq 'ctrlunitstate' ) {

		GardenaBLEDevice_getCharValue($hash,'ctrlunitstate');
	}

	return undef;
}
 
sub GardenaBLEDevice_stateRequest($) {

	my ($hash) = @_;
	my $name = $hash->{NAME};

	Log3 $name, 5, "GardenaBLEDevice_stateRequest ($name)";

	if ( !IsDisabled($name) ) {
		readingsSingleUpdate( $hash, "state", "requesting", 1 );
		GardenaBLEDevice_getCharValue ($hash, 'state'); 
	}
	else {
		readingsSingleUpdate( $hash, "state", "disabled", 1 );
	}
}

sub GardenaBLEDevice_stateRequestTimer($) {

	my ($hash) = @_;

	my $name = $hash->{NAME};
	my $model = $hash->{MODEL};
	
	if ( !IsDisabled($name) ) {

		RemoveInternalTimer($hash);
		
		readingsSingleUpdate( $hash, "state", "requesting", 1 );
		
		#Update relevant information
		foreach (keys %{%GardenaBLEDevice_Models{$model}}) { 
			GardenaBLEDevice_getCharValue ($hash, $_); 
		}

		InternalTimer( gettimeofday() + $hash->{INTERVAL} + int( rand(10) ), "GardenaBLEDevice_stateRequestTimer", $hash );

		Log3 $name, 5, "GardenaBLEDevice ($name) - stateRequestTimer: Call Request Timer";
	}
	else {
		Log3 $name, 5, "GardenaBLEDevice ($name) - stateRequestTimer: No execution as device is disabled.";
	}
}

#Get characteristics value
sub GardenaBLEDevice_getCharValue ($@) {
	
	my ( $hash, $uuid ) = @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};
	my $name = $hash->{NAME};
	
	Log3 $name, 5, "GardenaBLEDevice ($name) - getCharValue: ".$uuid;
	
	GardenaBLEDevice_CreateParamGatttool($hash, $mod, $GardenaBLEDevice_Models{$model}{$uuid});
}

sub GardenaBLEDevice_CreateParamGatttool($@) {

	my ( $hash, $mod, $uuid, $value ) = @_;
	my $name = $hash->{NAME};
	my $mac  = $hash->{BTMAC};
	my $model = $hash->{MODEL};
	
	$value = "" if($mod eq 'read');
	
	Log3 $name, 5, "GardenaBLEDevice ($name) - Run CreateParamGatttool with mod: $mod";

	if($hash->{helper}{RUNNING_PID}){
		
		my @param;
		
		if ($mod eq 'read') {
			@param = ($mod, $uuid);
		}
		elsif ($mod eq 'write') {
			@param = ($mod, $uuid, $value);
		}
		
		
		if (@{$hash->{helper}{GT_QUEUE}} < $hash->{MAXGATTQUEUE}) {
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - Run CreateParamGatttool Another job is running adding to pending: @param";
	
			push @{$hash->{helper}{GT_QUEUE}}, \@param;
		}
		else {
			Log3 $name, 2, "GardenaBLEDevice ($name) - Run CreateParamGatttool Maximum number of jobs reached, dropping newer ones.";
		}
		return;
	}

	if ( $mod eq 'read' ) {
		
		Log3 $name, 4, "GardenaBLEDevice ($name) - Read GardenaBLEDevice_ExecGatttool_Run $name|$mac|$mod|$uuid";
		
		$hash->{helper}{RUNNING_PID} = BlockingCall(
			"GardenaBLEDevice_ExecGatttool_Run",
			$name . "|"
			. $mac . "|"
			. $mod . "|"
			. $hash->{SLEEP_BETWEEN_GATT_CMDS} . "|"
			. $hash->{BTSECLEVEL} . "|"
			. $uuid,
			"GardenaBLEDevice_ExecGatttool_Done",
			$hash->{GATTTIMEOUT},
			"GardenaBLEDevice_ExecGatttool_Aborted",
			$hash
			);
	}
	elsif ( $mod eq 'write' ) {
		
		my $handle = $uuid;
		
		Log3 $name, 4, "GardenaBLEDevice ($name) - Write GardenaBLEDevice_ExecGatttool_Run $name|$mac|$mod|$uuid|$handle|$value";
		
		$hash->{helper}{RUNNING_PID} = BlockingCall(
			"GardenaBLEDevice_ExecGatttool_Run",
			$name . "|"
			. $mac . "|"
			. $mod . "|"
			. $hash->{SLEEP_BETWEEN_GATT_CMDS} . "|"
			. $hash->{BTSECLEVEL} . "|"
			. $handle . "|"
			. $value,
			"GardenaBLEDevice_ExecGatttool_Done",
			$hash->{GATTTIMEOUT},
			"GardenaBLEDevice_ExecGatttool_Aborted",
			$hash
		);
	}
}

sub GardenaBLEDevice_ExecGatttool_Run($) {

	my $string = shift;

	my ( $name, $mac, $gattCmd, $sleep, $seclevel, $uuid, $value ) = split( "\\|", $string );
	my $gatttool;
	my $json_response;

	$gatttool = qx(which gatttool);
	
	chomp $gatttool;

	if ( defined($gatttool) and ($gatttool) ) {

		my $cmd;
		my $loop;
		my @gtResult;

		my $hci=AttrVal( $name, "hciDevice", "hci0" );

#		$cmd .= "timeout 10 " if ($listen);
		$cmd .= "gatttool -i $hci -b $mac ";
		$cmd .= "-l ".$seclevel." ";
		$cmd .= "--char-read -u $uuid" if ( $gattCmd eq 'read' );
		$cmd .= "--char-write-req -a $uuid -n $value" if ( $gattCmd eq 'write' );
#		$cmd .= " --listen" if ($listen);
		$cmd .= " 2>&1 /dev/null";
		$cmd .= " && sleep ".$sleep;

		my $debug;

		$loop = 0;
		do {
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - ExecGatttool_Run: call gatttool with command: $cmd and loop $loop";

			@gtResult = split( "\n", qx($cmd) );

			Log3 $name, 5, "GardenaBLEDevice ($name) - ExecGatttool_Run: gatttool loop result ".join( ",", @gtResult );

			$debug = join( ",", @gtResult );

			$loop++;

			if(not defined($gtResult[0])){
				$gtResult[0] = 'connect error';
			}
			else{
				$gtResult[0] = 'connect error' if ($gtResult[0]=~/connect\ error:/ || $gtResult[0]=~/connect:/);
			}
		} while ( $loop < 5 and $gtResult[0] eq 'connect error' );
			
		Log3 $name, 5, "GardenaBLEDevice ($name) - ExecGatttool_Run: gatttool result ".join( ",", @gtResult );
		
		my %data_response;
		
		if ($gtResult[0] eq 'connect error') {
			
			$json_response = encode_json( {'msg' => 'connect error', 'details' => $debug} );
			
		}
		else {			
			foreach my $gtresult_line (@gtResult) {

				Log3 $name, 5, "GardenaBLEDevice ($name) - ExecGatttool_Run: gtresult_line ".$gtresult_line;
				
				if($gtresult_line=~/^handle:\ (0x[0-9a-fA-F]{4})[\ \t]+value:\ ([0-9a-fA-F\ ]+)/){
					$data_response{'msg'} = "char_read_uuid_response";
					$data_response{'handle'} = $1 if ($1);
					$data_response{'value'} = $2 if ($2);
				}
				else {
					$data_response{'msg'} = $gtresult_line;
				}
			}
			$json_response = encode_json( \%data_response );
		}
		
		if ( $gtResult[0] ne 'connect error') {
			return "$name|$mac|ok|$gattCmd|$uuid|$json_response";
		}
		else {
			return "$name|$mac|error|$gattCmd|$uuid|$json_response";
		}
	}
	else {
		$json_response = encode_json('no gatttool binary found. Please check if bluez-package is properly installed');
		return "$name|$mac|error|$gattCmd|$uuid|$json_response";
	}
}

sub GardenaBLEDevice_ExecGatttool_Done($) {

	my $string = shift;
	my ( $name, $mac, $respstate, $gattCmd, $uuid, $json_response) = split( "\\|", $string );

	my $hash = $defs{$name};

	delete( $hash->{helper}{RUNNING_PID} );
	
	if(scalar @{$hash->{helper}{GT_QUEUE}} > 0) {
		
		my $array = $hash->{helper}{GT_QUEUE};

		my $param = shift @$array;
		
		#Typically write command
		if(scalar @$param == 3) {
			GardenaBLEDevice_CreateParamGatttool( $hash, @$param[0], @$param[1], @$param[2] );	
		}
		#Typically read command
		elsif(scalar @$param == 2) {
			GardenaBLEDevice_CreateParamGatttool( $hash, @$param[0], @$param[1] );	
		}
		#Unexpected
		else {
			Log3 $name, 3, "GardenaBLEDevice ($name) - ExecGatttool_Done ERROR handling next queued command.";
		}
	}

	Log3 $name, 4, "GardenaBLEDevice ($name) - ExecGatttool_Done: Helper is disabled. Stop processing" if ( $hash->{helper}{DISABLED} );

	return if ( $hash->{helper}{DISABLED} );

	Log3 $name, 4, "GardenaBLEDevice ($name) - ExecGatttool_Done: gatttool return string: $string";

	my $decode_json = decode_json($json_response);

	if ($@) {
		Log3 $name, 3, "GardenaBLEDevice ($name) - ExecGatttool_Done: JSON error while request: $@";
	}

	if ( $respstate eq 'ok') {
		
		#Increase GATT counter
		$hash->{GATTCOUNT}++;
		
		#Reset error count
		$hash->{ERRORCOUNT} = 0;
		
		if($decode_json->{msg} eq 'char_read_uuid_response'){
			GardenaBLEDevice_ProcessingCharUUIDResponse( $hash, $gattCmd, $uuid, $decode_json->{handle}, $decode_json->{value});
		}
	}
	else {
		GardenaBLEDevice_ProcessingErrors( $hash, $decode_json->{msg});
		
		if($decode_json->{details}){
			Log3 $name, 3, "GardenaBLEDevice ($name) - ExecGatttool_Done last gatt error: ".$decode_json->{details};
		}
	}
}

sub GardenaBLEDevice_ExecGatttool_Aborted($) {

	my ($hash) = @_;
	my $name = $hash->{NAME};
	my %readings;

	delete( $hash->{helper}{RUNNING_PID} );
	
	GardenaBLEDevice_ProcessingErrors($hash,'The BlockingCall Process terminated unexpectedly: timed out');
}

sub GardenaBLEDevice_ProcessingCharUUIDResponse($@) {

	my ( $hash, $gattCmd, $uuid, $handle, $value ) = @_;

	my $name = $hash->{NAME};
	my $model = $hash->{MODEL};
	my $readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: uuid: $uuid | handle: $handle | value: $value";
	
	if ( $uuid eq $GardenaBLEDevice_Models{$model}{'firmware_revision'} ) {
		$readings = GardenaBLEDevice_HandleFirmware($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'timestamp'}) {
		
		if (!$hash->{helper}{$model}{timestamphandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting timestamphandle char value handle to: $handle";
			
			$hash->{helper}{$model}{timestamphandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleTimestamp($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'battery'}) {
		$readings = GardenaBLEDevice_WaterControlHandleBattery($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'state'}) {
		$readings = GardenaBLEDevice_WaterControlHandleState($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'ctrlunitstate'} ) {
		$readings = GardenaBLEDevice_WaterControlHandleCtrlUnitState($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'one-time-watering-duration'} ) {
		
		if (!$hash->{helper}{$model}{onetimewaterhandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting one-time-watering-duration char value handle to: $handle";
			
			$hash->{helper}{$model}{onetimewaterhandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleDuration($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'one-time-default-watering-time'} ) {
		
		if (!$hash->{helper}{$model}{onetimewaterdeftimehandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting one-time-default-watering-time char value handle to: $handle";
			
			$hash->{helper}{$model}{onetimewaterdeftimehandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleDefaultWateringTime($hash, $value);
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule1-wdays'} ) {
		
		if (!$hash->{helper}{$model}{schedule1wdayshandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule1wdayshandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule1wdayshandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleWday($hash, $value, 'schedule1-weekdays');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule1-starttime'} ) {
		
		if (!$hash->{helper}{$model}{schedule1starttimehandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule1starttimehandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule1starttimehandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleStartTime($hash, $value, 'schedule1-starttime');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule1-duration'} ) {
		
		if (!$hash->{helper}{$model}{schedule1durationhandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule1durationhandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule1durationhandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleDuration($hash, $value, 'schedule1-duration');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule2-wdays'} ) {
		
		if (!$hash->{helper}{$model}{schedule2wdayshandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule2wdayshandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule2wdayshandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleWday($hash, $value, 'schedule2-weekdays');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule2-starttime'} ) {
		
		if (!$hash->{helper}{$model}{schedule2starttimehandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule2starttimehandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule2starttimehandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleStartTime($hash, $value, 'schedule2-starttime');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule2-duration'} ) {
		
		if (!$hash->{helper}{$model}{schedule2durationhandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule2durationhandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule2durationhandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleDuration($hash, $value, 'schedule2-duration');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule3-wdays'} ) {
		
		if (!$hash->{helper}{$model}{schedule3wdayshandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule3wdayshandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule3wdayshandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleWday($hash, $value, 'schedule3-weekdays');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule3-starttime'} ) {
		
		if (!$hash->{helper}{$model}{schedule3starttimehandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule3starttimehandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule3starttimehandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleStartTime($hash, $value, 'schedule3-starttime');
	}
	elsif ( $uuid eq $GardenaBLEDevice_Models{$model}{'schedule3-duration'} ) {
		
		if (!$hash->{helper}{$model}{schedule3durationhandle}){
			
			Log3 $name, 4, "GardenaBLEDevice ($name) - GardenaBLEDevice_ProcessingCharUUIDResponse: Setting schedule3durationhandle char value handle to: $handle";
			
			$hash->{helper}{$model}{schedule3durationhandle} = $handle;
		}
		
		$readings = GardenaBLEDevice_WaterControlHandleScheduleDuration($hash, $value, 'schedule3-duration');
	}
	GardenaBLEDevice_WriteReadings( $hash, $readings );
}

sub GardenaBLEDevice_WaterControlHandleScheduleDuration($$$) {

	my ( $hash, $value, $reading ) = @_;

	my $name = $hash->{NAME};
	my %readings;
	my $duration;
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleScheduleDuration";
	
	$value =~ s/[^a-fA-F0-9]//g;

	#Big to little endian
	$value =~ /(..)(..)(..)(..)/;
	my $value_le = $4.$3.$2.$1;
	
	$duration = hex("0x".$value_le);
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleScheduleDuration: setting reading $reading to $duration";

	$readings{$reading} = $duration." seconds";
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleScheduleStartTime($$$) {

	my ( $hash, $value, $reading ) = @_;

	my $name = $hash->{NAME};
	my %readings;
	my $startime;
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleScheduleStartTime";
	
	$value =~ s/[^a-fA-F0-9]//g;
	
	#Big to little endian
	$value =~ /(..)(..)(..)(..)/;
	my $value_le = $4.$3.$2.$1;
	
	my $startTimeSecondsAfterMidnight = hex("0x".$value_le);
	
	$startime = sprintf("%02d:%02d:%02d",$startTimeSecondsAfterMidnight / 3600, ($startTimeSecondsAfterMidnight / 60) % 60, $startTimeSecondsAfterMidnight % 60); 
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleScheduleStartTime: setting reading $reading to $startime";
	
	$readings{$reading} = $startime;
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleScheduleWday($$$) {

	my ( $hash, $value, $reading ) = @_;

	my $name = $hash->{NAME};
	my %readings;
	my $weekdays;
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleScheduleWday";
	
	$value =~ s/[^a-fA-F0-9]//g;
	$value =~ s/([a-fA-F0-9]{2})/hex($1)/eg;
	
	if ($value == 0x00) {
		$weekdays = "n/a";
	}
	else {
		$weekdays .= "Mon" if ( $value & (1 << 0));
		$weekdays .= ",Tue" if ( $value & (1 << 1));
		$weekdays .= ",Wed" if ( $value & (1 << 2));
		$weekdays .= ",Thu" if ( $value & (1 << 3));
		$weekdays .= ",Fri" if ( $value & (1 << 4));
		$weekdays .= ",Sat" if ( $value & (1 << 5));
		$weekdays .= ",Sun" if ( $value & (1 << 6));
	
		$weekdays =~ s/^,//;
		$weekdays =~ s/,$//;
	}

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleScheduleWday: setting reading $reading to $weekdays";

	$readings{$reading} = $weekdays;
	
	return \%readings;
}

#Read firwmare via UUID 0x2a26 (Firmware Revision String)
sub GardenaBLEDevice_HandleFirmware($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - HandleFirmware";
	
	$value =~ s/[^a-fA-F0-9]//g;
	$value =~ s/([a-fA-F0-9]{2})/chr(hex($1))/eg;
	
	Log3 $name, 4, "GardenaBLEDevice ($name) - HandleFirmware: firmware: $value";
	
	$readings{'firmware'} = $value;
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleTimestamp($$) {
	
	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleTimestamp";
	
	$value =~ s/[^a-fA-F0-9]//g;
	
	#Big to little endian
	$value =~ /(..)(..)(..)(..)/;
	my $value_le = $4.$3.$2.$1;
	
	my $timestamp = hex("0x".$value_le);
	
	$readings{'deviceTime'} = strftime('%Y-%m-%d %H:%M:%S', gmtime($timestamp));
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleBattery($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleBattery";
	
	$value =~ s/[^a-fA-F0-9]//g;
	
	my $batterylevel = hex("0x".$value);
	
	$readings{'batteryLevel'} = $batterylevel."%";
	
	if ($batterylevel <= 33) {
		
		$readings{'battery'} = "low";
	}
	else {
		$readings{'battery'} = "ok";
	}
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleState($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleState";
	
	$value =~ s/[^a-fA-F0-9]//g;

	if ($value eq "01"){
		
		$readings{'state'} = "on";
	}
	else {
		$readings{'state'} = "off";
	}
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleDuration($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleDuration";
	
	$value =~ s/[^a-fA-F0-9]//g;
#	$value =~ s/0000$//;
	
	#Big to little endian
	$value =~ /(..)(..)(..)(..)/;
	my $value_le = $4.$3.$2.$1;
	
	$readings{'remainingTime'} = hex("0x".$value_le)." seconds";
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleDefaultWateringTime($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleDefaultWateringTime";
	
	$value =~ s/[^a-fA-F0-9]//g;
#	$value =~ s/0000$//;
	
	#Big to little endian
	$value =~ /(..)(..)(..)(..)/;
	my $value_le = $4.$3.$2.$1;
	
	$readings{'default-one-time-watering-time'} = hex("0x".$value_le)." seconds";
	
	return \%readings;
}

sub GardenaBLEDevice_WaterControlHandleCtrlUnitState($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 4, "GardenaBLEDevice ($name) - WaterControlHandleCtrlUnitState";
	
	$value =~ s/[^a-fA-F0-9]//g;
	
	if ($value eq "01"){
		
		$readings{'ctrlunitstate'} = "installed";
	}
	else {
		$readings{'ctrlunitstate'} = "removed";
	}
	
	return \%readings;
}

sub GardenaBLEDevice_WriteReadings($$) {

	my ( $hash, $readings ) = @_;

	my $name = $hash->{NAME};

	readingsBeginUpdate($hash);
	while ( my ( $r, $v ) = each %{$readings} ) {
	    readingsBulkUpdate( $hash, $r, $v );
	}

	if ($readings->{'lastGattError'}) {
		readingsBulkUpdateIfChanged( $hash, "state", 'error');
	}
	
	readingsEndUpdate( $hash, 1 );
}

sub GardenaBLEDevice_ProcessingErrors($$) {

	my ( $hash, $value ) = @_;

	my $name = $hash->{NAME};
	my %readings;

	Log3 $name, 5, "GardenaBLEDevice ($name) - ProcessingErrors";
	
	#Increase error count
	$hash->{ERRORCOUNT}++;
	
	if ($hash->{ERRORCOUNT} >= $hash->{MAXERRORCOUNT}) {
	
		GardenaBLEDevice_Disable($hash);
		readingsSingleUpdate( $hash, "state", "disabled (error)", 1 );
		Log3 $name, 2, "GardenaBLEDevice ($name) - disabled because MAXERRORCOUNT of ". $hash->{MAXERRORCOUNT} ." reached";
		
	}
	else {
		$readings{'lastGattError'} = $value;
		GardenaBLEDevice_WriteReadings( $hash, \%readings );
	}
}

sub GardenaBLEDevice_Disable ($){
	
	my $hash = shift;
	my $name = $hash->{NAME};
	
	#Set attribute disable
	$attr{$name}{disable} = 1;
	
	RemoveInternalTimer($hash);
	
	BlockingKill( $hash->{helper}{RUNNING_PID} ) if ( defined( $hash->{helper}{RUNNING_PID} ) );
	
	@{$hash->{helper}{GT_QUEUE}} = ();
	
	readingsSingleUpdate( $hash, "state", "disabled", 1 );
	
	#Reset error count
	$hash->{ERRORCOUNT} = 0;
	
	Log3 $name, 3, "GardenaBLEDevice ($name) - disabled";
}

1;
