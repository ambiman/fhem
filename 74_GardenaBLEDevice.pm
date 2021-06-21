###############################################################################
#
#  (c) 2021 Copyright: ambiman
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
#
###############################################################################

package main;

use strict;
use warnings;
use POSIX;
import JSON::XS;

my %Gardena_BLE_Models = (
    watercontrol => {
        'whandle'		=> '0x0071',
		'timestamp'		=> '0x0031',
		'battery'		=> '0x0029', ##Most likely the battery - or it's 0x002f
		'state'			=> '0x006b',
		'duration'		=> '0x0071',
		#'laststop'	 	=> '0x003a', ##TODO: History sprinkler data ?
		'ctrlunitstate'	=> '0x006e'
    }
);

my %Gardena_BLE_Set_Opts = (
	all => {
		'on' => undef
		# 'battery'	=> undef,
		# 'time'		=> undef
	},
	watercontrol => {
		'on-for-timer'	=> undef,
		'off'			=> undef
	}
);

my %Gardena_BLE_Get_Opts = (
	all => {
		#'time'	=> undef,
		#'batterylevel'	=> undef,
		'stateRequest'	=> undef
	},
	watercontrol => {
		'remainingTime'	=> undef,
		#'laststop'		=> undef,
		'ctrlunitstate' => undef
	}
);

sub GardenaBLEDevice_Initialize($) {
    my ($hash) = @_;

    $hash->{SetFn}    = "Gardena_BLE_Set";
    $hash->{GetFn}    = "Gardena_BLE_Get";
    $hash->{DefFn}    = "Gardena_BLE_Define";
    $hash->{NotifyFn} = "Gardena_BLE_Notify";
    $hash->{UndefFn}  = "Gardena_BLE_Undef";
    $hash->{AttrFn}   = "Gardena_BLE_Attr";
    $hash->{AttrList} =
        "disable:1 "
      . "interval "
	  . "default-on-time "
      . "hciDevice:hci0,hci1,hci2 "
      . "blockingCallLoglevel:2,3,4,5 "
      . $readingFnAttributes;
}

# declare prototype
sub Gardena_BLE_ExecGatttool_Run($);

sub Gardena_BLE_Define($$) {

    my ( $hash, $def ) = @_;
    my @param = split('[ \t]+', $def );
 	
	return "too few parameters: define <name> Gardena_BLE <BTMAC> <MODEL>" if ( @param != 4 );
	return "wrong input for model: choose one of " . join(' ', keys %Gardena_BLE_Models) if (@param >= 3) && (!defined(%Gardena_BLE_Models{$param[3]}));
	
    my $name = $param[0];
    my $mac  = $param[2];
	my $model = $param[3];

    $hash->{BTMAC}                       = $mac;
    $hash->{INTERVAL}                    = 300;
	$hash->{DEFAULT_ON_TIME}             = 1800;
	$hash->{MODEL}						 = $model;
	$hash->{NOTIFYDEV}                   = "global,$name";
	$attr{$name}{webCmd}				 = "on:off";
    $attr{$name}{room}					 = "GardenaBLE" if !defined($attr{$name}{room});
	
    $modules{Gardena_BLE}{defptr}{ $hash->{BTMAC} } = $hash;
	
	readingsSingleUpdate( $hash, "state", "initialized", 0 );
	
	# Set commands supported by every Gardena BLE device + model specific ones
	my %set_commands = (%{%Gardena_BLE_Set_Opts{all}}, %{%Gardena_BLE_Set_Opts{$model}});
	$hash->{helper}->{Set_CommandSet} = \%set_commands;
	
	# Get commands supported by every Gardena BLE device + model specific ones
	my %get_commands = (%{%Gardena_BLE_Get_Opts{all}}, %{%Gardena_BLE_Get_Opts{$model}});
	$hash->{helper}->{Get_CommandSet} = \%get_commands;
	
	my @jobs = ();
	
	#Array for pending GATT jobs
	$hash->{helper}{GT_QUEUE} = \@jobs;
	
    Log3 $name, 3, "Gardena_BLE ($name) - defined with BTMAC $hash->{BTMAC}";
	
    return undef;
}

sub Gardena_BLE_Undef($$) {

    my ( $hash, $arg ) = @_;

    my $mac  = $hash->{BTMAC};
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);
    BlockingKill( $hash->{helper}{RUNNING_PID} ) if ( defined( $hash->{helper}{RUNNING_PID} ) );
	
	#Todo: necessary ?
	delete ( $hash->{helper}{GT_QUEUE} ) if ( defined( $hash->{helper}{GT_QUEUE} ) );
	
    delete( $modules{Gardena_BLE}{defptr}{$mac} );
    Log3 $name, 3, "Sub Gardena_BLE_Undef ($name) - deleted device $name";
    return undef;
}

sub Gardena_BLE_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
	
	
	Log3($name, 4,"Gardena_BLE_Attr ($name) - cmd: $cmd | attrName: $attrName | attrVal: $attrVal" );
	
    if ( $attrName eq "disable" ) {
        if ( $cmd eq "set" and $attrVal eq "1" ) {
            RemoveInternalTimer($hash);
            readingsSingleUpdate( $hash, "state", "disabled", 1 );
            Log3 $name, 3, "Gardena_BLE ($name) - disabled";
        }
        elsif ( $cmd eq "del" ) {
            Log3 $name, 3, "Gardena_BLE ($name) - enabled";
			readingsSingleUpdate( $hash, "state", "pending", 1 );
        }
	}
	elsif ( $attrName eq "interval" ) {
		
			($hash);
        
		if ( $cmd eq "set" ) {
            if ( $attrVal < 30 ) {
                Log3($name, 3, "Gardena_BLE ($name) - interval too small, please use something >= 30 (sec), default is 300 (sec)");
                return "interval too small, please use something >= 30 (sec), default is 300 (sec)";
            }
            else {
                $hash->{INTERVAL} = $attrVal;
                Log3($name, 3,"Gardena_BLE ($name) - set interval to $attrVal");
            }
		}
		elsif ( $cmd eq "del" ) {
			$hash->{INTERVAL} = 300;
			Log3($name, 3,"Gardena_BLE ($name) - set interval to default value 300 (sec)");
		}
	}
	elsif ( $attrName eq "default-on-time" ) {
		
		if ( $cmd eq "set" ) {
            if ($attrVal > 5 && $attrVal <=28740)  {
                $hash->{DEFAULT_ON_TIME} = $attrVal;
                Log3($name, 3,"Gardena_BLE ($name) - set default-on-time to $attrVal");
            }
            else {
                Log3($name, 3, "Gardena_BLE ($name) - default-on-time too small, please use something >= 5 (sec) and <= 28740 (sec), default is 1800 (sec)");
                return "default-on-time too small, please use something >= 5 (sec) and <= 28740 (sec), default is 1800 (sec)";
            }
		}
		elsif ( $cmd eq "del" ) {
			$hash->{DEFAULT_ON_TIME} = 1800;
			Log3($name, 3,"Gardena_BLE ($name) - set default-on-time to default value 1800 (sec)");
		}
	}
	return undef;
}

sub Gardena_BLE_Notify($$) {

    my ( $hash, $dev ) = @_;
    my $name = $hash->{NAME};

    my $devname = $dev->{NAME};
    my $devtype = $dev->{TYPE};
    my $events  = deviceEvents( $dev, 1 );
	
	Log3 $name, 5, "Gardena_BLE_Notify ($name) - devname: $devname | devtype: $devtype | events: @$events";

    return if ( !$events );

	#Trigger state request
    Gardena_BLE_stateRequestTimer($hash)
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

sub Gardena_BLE_Set($@) {

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
		readingsSingleUpdate( $hash, "state", "set_on", 1 );
	
		Gardena_BLE_CreateParamGatttool( $hash, $mod, $Gardena_BLE_Models{$model}{whandle}, sprintf(uc(unpack("H*",pack("v*",$hash->{DEFAULT_ON_TIME})))."0000") );
		Gardena_BLE_stateRequest($hash);
		Gardena_BLE_getCharValue($hash,'duration');
	}
	elsif(lc $cmd eq 'off') {
		readingsSingleUpdate( $hash, "state", "set_off", 1 );	
		 
		Gardena_BLE_CreateParamGatttool( $hash, $mod, $Gardena_BLE_Models{$model}{whandle}, sprintf(uc(unpack("H*",pack("v*",0)))."0000") );
		Gardena_BLE_stateRequest($hash);
	}
	elsif(lc $cmd eq 'on-for-timer') {
		
		if ($value > 5 && $value <=28740) {
		
			readingsSingleUpdate( $hash, "state", "set_on-for-timer ".$value, 1 );

			Gardena_BLE_CreateParamGatttool( $hash, $mod, $Gardena_BLE_Models{$model}{whandle}, sprintf(uc(unpack("H*",pack("v*",$value)))."0000") );
			Gardena_BLE_stateRequest($hash);
			Gardena_BLE_getCharValue($hash,'duration');
		}
		else {
			return "Use set <device> on-for-timer [range 5-28740]";
		}	
	}
	else{
		return 0;
	}

}

sub Gardena_BLE_Get($$@) {

    my ( $hash, $name, @aa ) = @_;
    my ( $cmd, @args ) = @aa;

    my $mod = 'read';
	my $model = $hash->{MODEL};
    my $handle;
	
	Log3 $name, 5, "Gardena_BLE_Get ($name) - cmd: ".$cmd;
	
	return "Unknown argument $cmd, choose one of ". join(" ", keys %{$hash->{helper}{Get_CommandSet}}) if (!exists($hash->{helper}{Get_CommandSet}{$cmd}));
	
    if ( $cmd eq 'stateRequest' ) {
    
    	Gardena_BLE_stateRequest($hash);
	}
    elsif ( $cmd eq 'remainingTime' ) {
    
    	Gardena_BLE_getCharValue($hash,'duration');
	}
	#     elsif ( $cmd eq 'laststop' ) {
	#
	#     	getLastSprinklerTime($hash);
	# }
    elsif ( $cmd eq 'ctrlunitstate' ) {
    
    	Gardena_BLE_getCharValue($hash,'ctrlunitstate');
	}
	
    return undef;
 }
 
 sub Gardena_BLE_stateRequest($) {

     my ($hash) = @_;
     my $name = $hash->{NAME};
     my %readings;
	
 	my $model = $hash->{MODEL};
 	my $mod = 'read';
	
 	Log3 $name, 5, "Gardena_BLE_stateRequest ($name)";
	
 	if ( !IsDisabled($name) ) {
 		readingsSingleUpdate( $hash, "state", "requesting", 1 );
 		Gardena_BLE_CreateParamGatttool( $hash, $mod, $Gardena_BLE_Models{$model}{state} );
     }
     else {
         readingsSingleUpdate( $hash, "state", "disabled", 1 );
     }
 }

 sub Gardena_BLE_stateRequestTimer($) {

     my ($hash) = @_;

     my $name = $hash->{NAME};
	 
	 if ( !IsDisabled($name) ) {
	 	
		 RemoveInternalTimer($hash);
		
		 #Update relevant information
	     Gardena_BLE_stateRequest($hash);
	 
		 foreach ('battery', 'timestamp', 'duration', 'ctrlunitstate') { 
			 Gardena_BLE_getCharValue ($hash, $_); 
		 }
	 
	     InternalTimer( gettimeofday() + $hash->{INTERVAL} + int( rand(10) ),
	         "Gardena_BLE_stateRequestTimer", $hash );
		 
		 Log3 $name, 5, "Gardena_BLE ($name) - stateRequestTimer: Call Request Timer";
	 }
	 else {
		 Log3 $name, 5, "Gardena_BLE ($name) - stateRequestTimer: No execution as device disabled.";	 	
	 }
	 
 }

#Get remaining sprinkler time
sub Gardena_BLE_getCharValue ($@) {
	
	my ( $hash, $handle ) = @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};
	my $name = $hash->{NAME};
	
	Log3 $name, 5, "Gardena_BLE ($name) - getCharValue: ".$handle;
	
	Gardena_BLE_CreateParamGatttool( $hash, $mod, $Gardena_BLE_Models{$model}{$handle});
}

sub Gardena_BLE_CreateParamGatttool($@) {

    my ( $hash, $mod, $handle, $value ) = @_;
    my $name = $hash->{NAME};
    my $mac  = $hash->{BTMAC};
	my $model = $hash->{MODEL};
	
    Log3 $name, 5, "Gardena_BLE ($name) - Run CreateParamGatttool with mod: $mod";
	  
	if($hash->{helper}{RUNNING_PID}){
		
		my @param = ($mod, $handle, $value );
		
	    Log3 $name, 4, "Gardena_BLE ($name) - Run CreateParamGatttool Another job is running adding to pending: @param";
		
		push @{$hash->{helper}{GT_QUEUE}}, \@param;
		
		return;
	}

    if ( $mod eq 'read' ) {
		
		$hash->{helper}{RUNNING_PID} = BlockingCall(
            "Gardena_BLE_ExecGatttool_Run",
            $name . "|" . $mac . "|" . $mod . "|" . $handle,
            "Gardena_BLE_ExecGatttool_Done",
            90,
            "Gardena_BLE_ExecGatttool_Aborted",
            $hash
        );
		
        Log3 $name, 4, "Gardena_BLE ($name) - Read Gardena_BLE_ExecGatttool_Run $name|$mac|$mod|$handle";

    }
   elsif ( $mod eq 'write' ) {
	   
        $hash->{helper}{RUNNING_PID} = BlockingCall(
            "Gardena_BLE_ExecGatttool_Run",
            	$name . "|"
              . $mac . "|"
              . $mod . "|"
              . $handle . "|"
              . $value . "|",
            "Gardena_BLE_ExecGatttool_Done",
            90,
            "Gardena_BLE_ExecGatttool_Aborted",
            $hash
        );
		
        Log3 $name, 4, "Gardena_BLE ($name) - Write Gardena_BLE_ExecGatttool_Run $name|$mac|$mod|$handle|$value";
    }
}

sub Gardena_BLE_ExecGatttool_Run($) {

    my $string = shift;

    my ( $name, $mac, $gattCmd, $handle, $value, $listen ) =
      split( "\\|", $string );
    my $gatttool;
    my $json_notification;

    $gatttool = qx(which gatttool);
    chomp $gatttool;

    if ( defined($gatttool) and ($gatttool) ) {

        my $cmd;
        my $loop;
        my @gtResult;

        my $hci=AttrVal( $name, "hciDevice", "hci0" );

        $cmd .= "timeout 10 " if ($listen);
        $cmd .= "gatttool -i $hci -b $mac ";
        $cmd .= "--char-read -a $handle" if ( $gattCmd eq 'read' );
        $cmd .= "--char-write-req -a $handle -n $value" if ( $gattCmd eq 'write' );
        $cmd .= " --listen" if ($listen);
        $cmd .= " 2>&1 /dev/null";
		
		my $debug;
		
        $loop = 0;
        do {

            Log3 $name, 4, "Gardena_BLE ($name) - ExecGatttool_Run: call gatttool with command: $cmd and loop $loop";

	 		@gtResult = split( "\n", qx($cmd) );

            Log3 $name, 5, "Gardena_BLE ($name) - ExecGatttool_Run: gatttool loop result ".join( ",", @gtResult );
			
			$debug = join( ",", @gtResult );
            
			$loop++;
			
			if(not defined($gtResult[0])){
				$gtResult[0] = 'connect error';
			}
			else{
				$gtResult[0] = 'connect error' if ($gtResult[0]=~/connect\ error:/ || $gtResult[0]=~/connect:/);
			}
        } while ( $loop < 5 and $gtResult[0] eq 'connect error' );
			
        Log3 $name, 5, "Gardena_BLE ($name) - ExecGatttool_Run: gatttool result ".join( ",", @gtResult );
		
		my %data_response;
		
		if ($gtResult[0] eq 'connect error') {
			
			$json_notification = encode_json( {'msg' => 'connect error', 'details' => $debug} );
			
		}
		else {			
			foreach my $gtresult_line (@gtResult) {

		        Log3 $name, 5, "Gardena_BLE ($name) - ExecGatttool_Run: gtresult_line ".$gtresult_line;
				
				if ($gtresult_line=~/^Notification\ handle\ =\ (0x[0-9a-fA-F]{1,4})\ value:\ ([0-9a-fA-F\ ]+)/){
					
					$data_response{'msg'} = "Notification";
					$data_response{'handle'} = $1 if ($1);
					$data_response{'value'} = $2 if ($2);
				}
				elsif($gtresult_line=~/^Characteristic\ value\/descriptor:\ ([0-9a-fA-F\ ]+)/){
					$data_response{'msg'} = "Char_Value_Desc";
					$data_response{'value'} = $1;
				}
				else {
					$data_response{'msg'} = $gtresult_line;
				}
			}
			$json_notification = encode_json( \%data_response );
		}
		
		if ( $gtResult[0] ne 'connect error') {
            return "$name|$mac|ok|$gattCmd|$handle|$json_notification";
        }
        else {
            return "$name|$mac|error|$gattCmd|$handle|$json_notification";
        }
    }
    else {
        $json_notification = encode_json(
'no gatttool binary found. Please check if bluez-package is properly installed'
        );
        return "$name|$mac|error|$gattCmd|$handle|$json_notification";
    }
}

sub Gardena_BLE_ExecGatttool_Done($) {

    my $string = shift;
    my ( $name, $mac, $respstate, $gattCmd, $handle, $json_notification) =
      split( "\\|", $string );

    my $hash = $defs{$name};

    delete( $hash->{helper}{RUNNING_PID} );
	
	if(scalar @{$hash->{helper}{GT_QUEUE}} > 0) {
		
		my $array = $hash->{helper}{GT_QUEUE};

		my $param = shift @$array;
		
		#Typically write command
		if(scalar @$param == 3) {
			Gardena_BLE_CreateParamGatttool( $hash, @$param[0], @$param[1], @$param[2] );	
		}
		#Typically read command
		elsif(scalar @$param == 2) {
			Gardena_BLE_CreateParamGatttool( $hash, @$param[0], @$param[1] );	
		}
		#Unexpected
		else {
		    Log3 $name, 3, "Gardena_BLE ($name) - ExecGatttool_Done ERROR handling next queued command.";
		}
	}

    Log3 $name, 4, "Gardena_BLE ($name) - ExecGatttool_Done: Helper is disabled. Stop processing" if ( $hash->{helper}{DISABLED} );
	
    return if ( $hash->{helper}{DISABLED} );

    Log3 $name, 4, "Gardena_BLE ($name) - ExecGatttool_Done: gatttool return string: $string";

    my $decode_json = decode_json($json_notification);
	
    if ($@) {
        Log3 $name, 3, "Gardena_BLE ($name) - ExecGatttool_Done: JSON error while request: $@";
    }

	if ( $respstate eq 'ok') {
		
		if($decode_json->{msg} eq 'Char_Value_Desc'){
			Gardena_BLE_ProcessingCharValueDesc( $hash, $gattCmd, $handle, $decode_json->{value});
		}
	}
    else {
        Gardena_BLE_ProcessingErrors( $hash, $decode_json->{msg});
		
		if($decode_json->{details}){
			Log3 $name, 3, "Gardena_BLE ($name) - ExecGatttool_Done last gatt error: ".$decode_json->{details};
		}
    }
}

sub Gardena_BLE_ExecGatttool_Aborted($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    my %readings;

    delete( $hash->{helper}{RUNNING_PID} );
	
    readingsSingleUpdate( $hash, "state", "unreachable", 1 );

    $readings{'lastGattError'} =
      'The BlockingCall Process terminated unexpectedly. Timedout';
    Gardena_BLE_WriteReadings( $hash, \%readings );

    Log3 $name, 3, "Gardena_BLE ($name) - ExecGatttool_Aborted: The BlockingCall Process terminated unexpectedly. Timeout";
}

sub Gardena_BLE_ProcessingCharValueDesc($@) {

    my ( $hash, $gattCmd, $handle, $value ) = @_;

    my $name = $hash->{NAME};
	my $model = $hash->{MODEL};
    my $readings;

    Log3 $name, 4, "Gardena_BLE ($name) - ProcessingCharValueDesc: handle: $handle | value: $value";
	
    if ( $model eq 'watercontrol' ) {
		if ( $handle eq $Gardena_BLE_Models{$model}{timestamp}) {
            $readings = Gardena_BLE_WaterControlHandleTimestamp($hash, $value);
        }
        elsif ( $handle eq $Gardena_BLE_Models{$model}{battery}) {
            $readings = Gardena_BLE_WaterControlHandleBattery($hash, $value);
        }
        elsif ( $handle eq $Gardena_BLE_Models{$model}{state}) {
            $readings = Gardena_BLE_WaterControlHandleState($hash, $value);
        }
        elsif ( $handle eq $Gardena_BLE_Models{$model}{duration} ) {
            $readings = Gardena_BLE_WaterControlHandleDuration($hash, $value);
        }
        elsif ( $handle eq $Gardena_BLE_Models{$model}{ctrlunitstate} ) {
            $readings = Gardena_BLE_WaterControlHandleCtrlUnitState($hash, $value);
        }
    }
    Gardena_BLE_WriteReadings( $hash, $readings );
}

sub Gardena_BLE_WaterControlHandleTimestamp($$) {
	
    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 4, "Gardena_BLE ($name) - WaterControlHandleTimestamp";
	
	$notification =~ s/[^a-fA-F0-9]//g;
	
	#Big to little endian
	$notification =~ /(..)(..)(..)(..)/;
	my $notification_le = $4.$3.$2.$1;
	
	my $timestamp = hex("0x".$notification_le);
	
	$readings{'deviceTime'} = scalar(gmtime($timestamp));
	
	return \%readings;
}

sub Gardena_BLE_WaterControlHandleBattery($$) {

    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 4, "Gardena_BLE ($name) - WaterControlHandleBattery";
	
	$notification =~ s/[^a-fA-F0-9]//g;
	
	my $batterylevel = hex("0x".$notification);
	
	$readings{'batteryLevel'} = $batterylevel."%";
	
	if ($batterylevel <= 10) {
		
		$readings{'battery'} = "low";
	}
	else {
		$readings{'battery'} = "ok";
	}
	return \%readings;
}

sub Gardena_BLE_WaterControlHandleState($$) {

    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 4, "Gardena_BLE ($name) - WaterControlHandleState";
	
	$notification =~ s/[^a-fA-F0-9]//g;

	if ($notification eq "01"){
		
		$readings{'state'} = "on";
	}
	else {
		$readings{'state'} = "off";
	}
	
	return \%readings;
}

sub Gardena_BLE_WaterControlHandleDuration($$) {

    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 4, "Gardena_BLE ($name) - WaterControlHandleDuration";
	
	$notification =~ s/[^a-fA-F0-9]//g;
	$notification =~ s/0000$//;
	
	#Big to little endian
	$notification =~ /(..)(..)/;
	my $notifcaiton_le = $2.$1;
	
	$readings{'remainingTime'} = hex("0x".$notifcaiton_le)." seconds";
	
	return \%readings;
}


sub Gardena_BLE_WaterControlHandleCtrlUnitState($$) {

    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 4, "Gardena_BLE ($name) - WaterControlHandleCtrlUnitState";
	
	$notification =~ s/[^a-fA-F0-9]//g;
	
	if ($notification eq "01"){
		
		$readings{'ctrlunitstate'} = "installed";
	}
	else {
		$readings{'ctrlunitstate'} = "removed";
	}
	
	return \%readings;
}

sub Gardena_BLE_WriteReadings($$) {

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

sub Gardena_BLE_ProcessingErrors($$) {

    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 5, "Gardena_BLE ($name) - ProcessingErrors";
	
    $readings{'lastGattError'} = $notification;

    Gardena_BLE_WriteReadings( $hash, \%readings );
}

1;
