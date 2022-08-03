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
#  Version: 0.2
###############################################################################

package main;

use strict;
use warnings;
use POSIX;
use JSON::XS;

my $version = '0.2';

my %GardenaBLEDevice_Models = (
	watercontrol => {
		'timestamp'							=> '98bd0b13-0b0e-421a-84e5-ddbf75dc6de4',
		'battery'							=> '98bd2a19-0b0e-421a-84e5-ddbf75dc6de4',
		'state'								=> '98bd0f11-0b0e-421a-84e5-ddbf75dc6de4',
		'one-time-watering-duration'		=> '98bd0f13-0b0e-421a-84e5-ddbf75dc6de4',
		'one-time-default-watering-time'	=> '98bd0f14-0b0e-421a-84e5-ddbf75dc6de4',
		'ctrlunitstate'						=> '98bd0f12-0b0e-421a-84e5-ddbf75dc6de4',
		'firmware_revision'					=> '00002a26-0000-1000-8000-00805f9b34fb' 	#Firmware Revision String
	}
);

my %GardenaBLEDevice_Set_Opts = (
	all => {
		'on' => undef
	},
	watercontrol => {
		'on-for-timer'	=> undef,
		'off'			=> undef,
		'default-watering-time' => undef
	}
);

my %GardenaBLEDevice_Get_Opts = (
	all => {
		'stateRequest'	=> undef
	},
	watercontrol => {
		'remainingTime'	=> undef,
		'ctrlunitstate' => undef
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
	$hash->{GATTCOUNT}					= 0;
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

			RemoveInternalTimer($hash);
			readingsSingleUpdate( $hash, "state", "disabled", 1 );
			Log3 $name, 3, "GardenaBLEDevice ($name) - disabled";
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
			if ($attrVal > 5 && $attrVal <=65535)  {
				$hash->{DEFAULT_ON_TIME_FHEM} = $attrVal;
				Log3($name, 3,"GardenaBLEDevice ($name) - set default-on-time-fhem to $attrVal");
			}
			else {
				Log3($name, 3, "GardenaBLEDevice ($name) - default-on-time-fhem too small, please use something >= 5 (sec) and <= 65535 (sec), default is 1800 (sec)");
				return "default-on-time-fhem too small, please use something >= 5 (sec) and <= 65535 (sec), default is 1800 (sec)";
			}
		}
		elsif ( $cmd eq "del" ) {
			$hash->{DEFAULT_ON_TIME_FHEM} = 1800;
			Log3($name, 3,"GardenaBLEDevice ($name) - set default-on-time-fhem to default value 1800 (sec)");
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
			or grep /^DELETEATTR.$name.$name.disable$/,
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

	my ($name, $cmd, $value)  = @param;
	
	my $mod = 'write';
	my $model = $hash->{MODEL};
	
	my $supported_cmd=0;
	
	return 0 if ( IsDisabled($name) );
	
	foreach my $command (keys %{$hash->{helper}{Set_CommandSet}}) {
		
		$command=~s/:.*//;
		
		if(lc $command eq $cmd){
			$supported_cmd=1;
		}
	}
	
	return "Unknown argument $cmd, choose one of " . join(" ", keys %{$hash->{helper}{Set_CommandSet}}) if ($supported_cmd==0);
		
	if (lc $cmd eq 'on') {
		
		if ($hash->{helper}{$model}{onetimewaterhandle}) {

			readingsSingleUpdate( $hash, "state", "set_on", 1 );
	
			GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterhandle}, sprintf(uc(unpack("H*",pack("v*",$hash->{DEFAULT_ON_TIME_FHEM})))."0000") );
			GardenaBLEDevice_stateRequest($hash);
			GardenaBLEDevice_getCharValue($hash, 'one-time-watering-duration');
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_on: onetimewaterhandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterhandle char value handle does not exist");
			
			return "Error: onetimewaterhandle char value handle does not exist."
		}
	}
	elsif(lc $cmd eq 'off') {
		
		if ($hash->{helper}{$model}{onetimewaterhandle}) {
			
			readingsSingleUpdate( $hash, "state", "set_off", 1 );	
		 
			GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterhandle}, sprintf(uc(unpack("H*",pack("v*",0)))."0000") );
			GardenaBLEDevice_stateRequest($hash);
			GardenaBLEDevice_getCharValue($hash, 'one-time-watering-duration');
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_off: onetimewaterhandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterhandle char value handle does not exist");
			
			return "Error: onetimewaterhandle char value handle does not exist."
		}
	}
	elsif(lc $cmd eq 'on-for-timer') {
		
		if ($hash->{helper}{$model}{onetimewaterhandle}) {
		
			if ($value > 5 && $value <=65535) {
		
				readingsSingleUpdate( $hash, "state", "set_on-for-timer ".$value, 1 );

				GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterhandle}, sprintf(uc(unpack("H*",pack("v*",$value)))."0000") );
				GardenaBLEDevice_stateRequest($hash);
				GardenaBLEDevice_getCharValue($hash, 'one-time-watering-duration');
			}
			else {
				return "Use set <device> on-for-timer [range 5-65535]";
			}
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_on-for-timer: onetimewaterhandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterhandle char value handle does not exist");
			
			return "Error: onetimewaterhandle char value handle does not exist."
		}
	}
	elsif(lc $cmd eq 'default-watering-time') {
		
		if ($hash->{helper}{$model}{onetimewaterdeftimehandle}) {
		
			if ($value > 5 && $value <=65535) {
		
				readingsSingleUpdate( $hash, "state", "set_default-watering-time ".$value, 1 );

				GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $hash->{helper}{$model}{onetimewaterdeftimehandle}, sprintf(uc(unpack("H*",pack("v*",$value)))."0000") );
				GardenaBLEDevice_stateRequest($hash);
				GardenaBLEDevice_getCharValue($hash,'one-time-default-watering-time');
			}
			else {
				return "Use set <device> default-watering-time [range 5-65535]";
			}
		}
		else {
		
			Log3 $name, 2, "GardenaBLEDevice ($name) - GardenaBLEDevice_Set cmd_on-for-timer: onetimewaterdeftimehandle char value handle does not exist.";
			
			GardenaBLEDevice_ProcessingErrors($hash, "onetimewaterdeftimehandle char value handle does not exist");
			
			return "Error: onetimewaterdeftimehandle char value handle does not exist."
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
	my %readings;

	my $model = $hash->{MODEL};
	my $mod = 'read';

	Log3 $name, 5, "GardenaBLEDevice_stateRequest ($name)";

	if ( !IsDisabled($name) ) {
		readingsSingleUpdate( $hash, "state", "requesting", 1 );
		GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $GardenaBLEDevice_Models{$model}{'state'} );
	}
	else {
		readingsSingleUpdate( $hash, "state", "disabled", 1 );
	}
}

sub GardenaBLEDevice_stateRequestTimer($) {

	my ($hash) = @_;

	my $name = $hash->{NAME};

	if ( !IsDisabled($name) ) {

		RemoveInternalTimer($hash);

		#Update relevant information
		GardenaBLEDevice_stateRequest($hash);

		foreach ('firmware_revision', 'battery', 'timestamp', 'ctrlunitstate', 'one-time-watering-duration', 'one-time-default-watering-time') { 
			GardenaBLEDevice_getCharValue ($hash, $_); 
		}

		InternalTimer( gettimeofday() + $hash->{INTERVAL} + int( rand(10) ), "GardenaBLEDevice_stateRequestTimer", $hash );

		Log3 $name, 5, "GardenaBLEDevice ($name) - stateRequestTimer: Call Request Timer";
	}
	else {
		Log3 $name, 5, "GardenaBLEDevice ($name) - stateRequestTimer: No execution as device disabled.";
	}
}

#Get characteristics value
sub GardenaBLEDevice_getCharValue ($@) {
	
	my ( $hash, $uuid ) = @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};
	my $name = $hash->{NAME};
	
	Log3 $name, 5, "GardenaBLEDevice ($name) - getCharValue: ".$uuid;
	
	GardenaBLEDevice_CreateParamGatttool( $hash, $mod, $GardenaBLEDevice_Models{$model}{$uuid});
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
		
		Log3 $name, 4, "GardenaBLEDevice ($name) - Run CreateParamGatttool Another job is running adding to pending: @param";
	
		push @{$hash->{helper}{GT_QUEUE}}, \@param;
		
		return;
	}

	if ( $mod eq 'read' ) {
		
		Log3 $name, 4, "GardenaBLEDevice ($name) - Read GardenaBLEDevice_ExecGatttool_Run $name|$mac|$mod|$uuid";
		
		$hash->{helper}{RUNNING_PID} = BlockingCall(
			"GardenaBLEDevice_ExecGatttool_Run",
			$name . "|" . $mac . "|" . $mod . "|" . $uuid,
			"GardenaBLEDevice_ExecGatttool_Done",
			90,
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
			. $handle . "|"
			. $value . "|",
			"GardenaBLEDevice_ExecGatttool_Done",
			90,
			"GardenaBLEDevice_ExecGatttool_Aborted",
			$hash
		);
	}
}

sub GardenaBLEDevice_ExecGatttool_Run($) {

	my $string = shift;

	my ( $name, $mac, $gattCmd, $uuid, $value, $listen ) = split( "\\|", $string );
	my $gatttool;
	my $json_response;

	$gatttool = qx(which gatttool);
	
	chomp $gatttool;

	if ( defined($gatttool) and ($gatttool) ) {

		my $cmd;
		my $loop;
		my @gtResult;

		my $hci=AttrVal( $name, "hciDevice", "hci0" );

		$cmd .= "timeout 10 " if ($listen);
		$cmd .= "gatttool -i $hci -b $mac ";
		$cmd .= "--char-read -u $uuid" if ( $gattCmd eq 'read' );
		$cmd .= "--char-write-req -a $uuid -n $value" if ( $gattCmd eq 'write' );
		$cmd .= " --listen" if ($listen);
		$cmd .= " 2>&1 /dev/null";

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
		
		$hash->{GATTCOUNT}++;
		
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

	readingsSingleUpdate( $hash, "state", "unreachable", 1 );

	$readings{'lastGattError'} = 'The BlockingCall Process terminated unexpectedly. Timedout';
	GardenaBLEDevice_WriteReadings( $hash, \%readings );

	Log3 $name, 3, "GardenaBLEDevice ($name) - ExecGatttool_Aborted: The BlockingCall Process terminated unexpectedly. Timeout";
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

	GardenaBLEDevice_WriteReadings( $hash, $readings );
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
	
	$readings{'deviceTime'} = scalar(gmtime($timestamp));
	
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
	
	if ($batterylevel <= 10) {
		
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

	$readings{'lastGattError'} = $value;

	GardenaBLEDevice_WriteReadings( $hash, \%readings );
}

1;
