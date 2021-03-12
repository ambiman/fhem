###############################################################################
#
#  (c) 2020 Copyright: ambiman
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

my %YeelightModels = (
    candela => {
        'whandle'		 => '0x1f',
		'on'			 => '434001',
		'off'			 => '434002',
		'state'			 => '434400',
		'dim'			 => '4342',
		'namehandle'	 => '0x0003',
		'fwhandle'		 => '0x0009',
		'manufacthandle' => '0x000b',
		'modelhandle'	 => '0x000d',
		'wdatalisten'	 => 1
    }
);

my %Yeelight_Set_Opts = (
	all => {
		'on'		=> undef,
		'off'		=> undef,
		'toggle'	=> undef
	},
	candela => {
		'dimup'							=> undef,
		'dimdown'						=> undef,
		'pct:colorpicker,BRI,0,1,100'	=> undef
	}
);

my %Yeelight_Get_Opts = (
	all => {
		'staterequest'	=> undef,
		'devicename'	=> undef
	}
);

sub Yeelight_BLE_Initialize($) {

    my ($hash) = @_;

    $hash->{SetFn}    = "Yeelight_BLE_Set";
    $hash->{GetFn}    = "Yeelight_BLE_Get";
    $hash->{DefFn}    = "Yeelight_BLE_Define";
    $hash->{NotifyFn} = "Yeelight_BLE_Notify";
    $hash->{UndefFn}  = "Yeelight_BLE_Undef";
    $hash->{AttrFn}   = "Yeelight_BLE_Attr";
    $hash->{AttrList} =
        "disable:1 "
      . "interval "
      . "hciDevice:hci0,hci1,hci2 "
      . "blockingCallLoglevel:2,3,4,5 "
      . $readingFnAttributes;
}

# declare prototype
sub ExecGatttool_Run($);

sub Yeelight_BLE_Define($$) {

    my ( $hash, $def ) = @_;
    my @param = split('[ \t]+', $def );
 	
	return "too few parameters: define <name> Yeelight_BLE <BTMAC> <MODEL>" if ( @param != 4 );
	return "wrong input for model: choose one of " . join(' ', keys %YeelightModels) if (@param >= 3) && (!defined($YeelightModels{$param[3]}));
	
    my $name = $param[0];
    my $mac  = $param[2];
	my $model = $param[3];

    $hash->{BTMAC}                       = $mac;
    $hash->{INTERVAL}                    = 300;
	$hash->{MODEL}						 = $model;
	$hash->{NOTIFYDEV}                   = "global,$name";
	$attr{$name}{webCmd}				 = "on:off:toggle";
    $attr{$name}{room}					 = "YeeLight" if !defined($attr{$name}{room});
	
    $modules{Yeelight_BLE}{defptr}{ $hash->{BTMAC} } = $hash;
	
	readingsSingleUpdate( $hash, "state", "initialized", 0 );
	
	# Set commands supported by every yeelight + model specific ones
	my %set_commands = (%{$Yeelight_Set_Opts{all}}, %{$Yeelight_Set_Opts{$model}});
	$hash->{helper}->{Set_CommandSet} = \%set_commands;
	
	# Get commands supported by every yeelight
	$hash->{helper}->{Get_CommandSet} = \%{$Yeelight_Get_Opts{all}};
	
	my @jobs = ();
	
	#Array for pending GATT jobs
	$hash->{helper}{GT_QUEUE} = \@jobs;
	
    Log3 $name, 3, "Yeelight_BLE ($name) - defined with BTMAC $hash->{BTMAC}";
	
	#Get some informational stuff
	getDeviceName($hash);
	getFirmwareRevision($hash);
	getDeviceManufacturer($hash);
	getDeviceModel($hash);
	
    return undef;
}

sub Yeelight_BLE_Undef($$) {

    my ( $hash, $arg ) = @_;

    my $mac  = $hash->{BTMAC};
    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);
    BlockingKill( $hash->{helper}{RUNNING_PID} ) if ( defined( $hash->{helper}{RUNNING_PID} ) );
	
	#Todo: necessary ?
	delete ( $hash->{helper}{GT_QUEUE} ) if ( defined( $hash->{helper}{GT_QUEUE} ) );
	
    delete( $modules{Yeelight_BLE}{defptr}{$mac} );
    Log3 $name, 3, "Sub Yeelight_BLE_Undef ($name) - deleted device $name";
    return undef;
}

sub Yeelight_BLE_Attr(@) {

    my ( $cmd, $name, $attrName, $attrVal ) = @_;
    my $hash = $defs{$name};
	
	
	Log3($name, 4,"Yeelight_BLE_Attr ($name) - cmd: $cmd | attrName: $attrName | attrVal: $attrVal" );
	
    if ( $attrName eq "disable" ) {
        if ( $cmd eq "set" and $attrVal eq "1" ) {
            RemoveInternalTimer($hash);

            readingsSingleUpdate( $hash, "state", "disabled", 1 );
            Log3 $name, 3, "Yeelight_BLE ($name) - disabled";
        }
        elsif ( $cmd eq "del" ) {
            Log3 $name, 3, "Yeelight_BLE ($name) - enabled";
        }
	}
	elsif ( $attrName eq "interval" ) {
		
		RemoveInternalTimer($hash);
        
		if ( $cmd eq "set" ) {
            if ( $attrVal < 30 ) {
                Log3($name, 3, "Yeelight_BLE ($name) - interval too small, please use something >= 30 (sec), default is 300 (sec)");
                return "interval too small, please use something >= 30 (sec), default is 300 (sec)";
            }
            else {
                $hash->{INTERVAL} = $attrVal;
                Log3($name, 3,"Yeelight_BLE ($name) - set interval to $attrVal");
            }
		}
		elsif ( $cmd eq "del" ) {
			$hash->{INTERVAL} = 300;
			Log3($name, 3,"Yeelight_BLE ($name) - set interval to default value 300 (sec)");
		}
	}
	return undef;
}

sub Yeelight_BLE_Notify($$) {

    my ( $hash, $dev ) = @_;
    my $name = $hash->{NAME};
    return Yeelight_BLE_stateRequestTimer($hash) if ( IsDisabled($name) );

    my $devname = $dev->{NAME};
    my $devtype = $dev->{TYPE};
    my $events  = deviceEvents( $dev, 1 );
	
	Log3 $name, 5, "Yeelight_BLE_Notify ($name) - devname: $devname | devtype: $devtype | events: @$events";

    return if ( !$events );

	#Trigger state request
    Yeelight_BLE_stateRequestTimer($hash)
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

sub stateRequest($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    my %readings;
	
	my $model = $hash->{MODEL};
	my $mod = 'write';
	
	Log3 $name, 5, "Yeelight_stateRequest ($name)";
	
	if ( !IsDisabled($name) ) {
		readingsSingleUpdate( $hash, "state", "requesting", 1 );
		CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{state});
    }
    else {
        readingsSingleUpdate( $hash, "state", "disabled", 1 );
    }
}

sub Yeelight_BLE_stateRequestTimer($) {

    my ($hash) = @_;

    my $name = $hash->{NAME};

    RemoveInternalTimer($hash);
    stateRequest($hash);

    InternalTimer( gettimeofday() + $hash->{INTERVAL} + int( rand(300) ),
        "Yeelight_BLE_stateRequestTimer", $hash );

    Log3 $name, 5, "Yeelight_BLE ($name) - Yeelight_BLE_stateRequestTimer: Call Request Timer";
}

sub Yeelight_BLE_Set($@) {

    my ( $hash, @param ) = @_;

	my ($name, $cmd, $value)  = @param;
	
	my $mod = 'write';
	my $model = $hash->{MODEL};
	
	my $supported_cmd=0;
	
	foreach my $command (keys %{$hash->{helper}{Set_CommandSet}}) {
		
		$command=~s/:.*//;
		
		if(lc $command eq $cmd){
			$supported_cmd=1;
		}
	}

	return "Unknown argument $cmd, choose one of " . join(" ", keys %{$hash->{helper}{Set_CommandSet}}) if ($supported_cmd==0);

	if (lc $cmd eq 'on') {
		readingsSingleUpdate( $hash, "state", "set_on", 1 );
	
		CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{lc $cmd});
	}
	elsif(lc $cmd eq 'off') {
		readingsSingleUpdate( $hash, "state", "set_off", 1 );	
		
		CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{lc $cmd});	
	}
	elsif(lc $cmd eq 'pct') {
		
		if ($value > 0 && $value <=100) {
		
			readingsSingleUpdate( $hash, "state", "set_dim".$value."%", 1 );

			CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{dim}.sprintf("%02X", $value));
		}
		else {
			return "Use set <device> pct [range 1-100]";
		}	
	}
	elsif(lc $cmd eq 'dimup') {
		
		my $curr_pct = ReadingsVal($name,"pct",100);
		my $state = ReadingsVal($name,"state","off");
		
		if (!$value) {
			
			if ($state eq 'off') {
				$value=25;
			}
			else {
				if ($curr_pct <= 75){
			
					$value=$curr_pct + 25;
				}
				else {
					$value=100;
				}
			}
		}
		else {
			return  "Use set <device> dimup [range 1-100]" if ($value < 1 || $value >100);
		}

		readingsSingleUpdate( $hash, "state", "set_dim".$value."%", 1 );
		
		CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{dim}.sprintf("%02X", $value));	
	}
	elsif(lc $cmd eq 'dimdown') {
		
		return if(ReadingsVal($name,"state","off") eq "off");
		
		my $curr_pct = ReadingsVal($name,"pct",100);
		
		if (!$value) {
			if ($curr_pct > 25){
			
				$value=$curr_pct - 25;
			}
			else {
				readingsSingleUpdate( $hash, "state", "set_off", 1 );	
		
				CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{off});
				
				return;
			}
		}
		else {
			return  "Use set <device> dimdown [range 1-100]" if ($value < 1 || $value >100);
		}
		
		readingsSingleUpdate( $hash, "state", "set_dim".$value."%", 1 );
		
		CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{dim}.sprintf("%02X", $value));
	}
	elsif(lc $cmd eq "toggle" ) {
	    $cmd = ReadingsVal($name,"state",1) ? "off" : "on";
		
		CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{whandle}, $YeelightModels{$model}{lc $cmd});
	}
	else{
		return 0;
	}
}

sub Yeelight_BLE_Get($$@) {

    my ( $hash, $name, @aa ) = @_;
    my ( $cmd, @args ) = @aa;

    my $mod = 'read';
	my $model = $hash->{MODEL};
    my $handle;
	
	return "Unknown argument $cmd, choose one of ". join(" ", keys %{$hash->{helper}{Get_CommandSet}}) if (!exists($hash->{helper}{Get_CommandSet}{lc $cmd}));
	
    if ( $cmd eq 'staterequest' ) {
    
    	stateRequest($hash);
	}
    elsif ( $cmd eq 'devicename' ) {
    
    	getDeviceName($hash);
	}
	
    return undef;
 }

#Get device name
sub getDeviceName ($@){
	
	my $hash = shift @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};
	
	readingsSingleUpdate( $hash, "state", "requesting_devname", 1 );
	
	CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{namehandle});
}

#Get firwmare revision
sub getFirmwareRevision ($@){
	
	my $hash = shift @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};
	
	readingsSingleUpdate( $hash, "state", "requesting_fwrev", 1 );
	
	CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{fwhandle});
}

#Get firwmare revision
sub getDeviceManufacturer ($@){
	
	my $hash = shift @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};
	
	readingsSingleUpdate( $hash, "state", "requesting_manufacturer", 1 );
	
	CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{manufacthandle});
}
		
#Get model id
sub getDeviceModel ($@){

	my $hash = shift @_;
	my $mod = 'read';
	my $model = $hash->{MODEL};

	readingsSingleUpdate( $hash, "state", "requesting_model", 1 );

	CreateParamGatttool( $hash, $mod, $YeelightModels{$model}{modelhandle});
}

sub CreateParamGatttool($@) {

    my ( $hash, $mod, $handle, $value ) = @_;
    my $name = $hash->{NAME};
    my $mac  = $hash->{BTMAC};
	my $model = $hash->{MODEL};
	
    Log3 $name, 5, "Yeelight_BLE ($name) - Run CreateParamGatttool with mod: $mod";
	  
	if($hash->{helper}{RUNNING_PID}){
		
		my @param = ($mod, $handle, $value );
		
	    Log3 $name, 4, "Yeelight_BLE ($name) - Run CreateParamGatttool Another job is running adding to pending: @param";
		
		push @{$hash->{helper}{GT_QUEUE}}, \@param;
		
		return;
	}

    if ( $mod eq 'read' ) {
		
		$hash->{helper}{RUNNING_PID} = BlockingCall(
            "Yeelight_BLE_ExecGatttool_Run",
            $name . "|" . $mac . "|" . $mod . "|" . $handle,
            "Yeelight_BLE_ExecGatttool_Done",
            90,
            "Yeelight_BLE_ExecGatttool_Aborted",
            $hash
        );
		
        Log3 $name, 4, "Yeelight_BLE ($name) - Read Yeelight_BLE_ExecGatttool_Run $name|$mac|$mod|$handle";

    }
   elsif ( $mod eq 'write' ) {
	   
        $hash->{helper}{RUNNING_PID} = BlockingCall(
            "Yeelight_BLE_ExecGatttool_Run",
            	$name . "|"
              . $mac . "|"
              . $mod . "|"
              . $handle . "|"
              . $value . "|"		
			  . $YeelightModels{$model}{wdatalisten},
            "Yeelight_BLE_ExecGatttool_Done",
            90,
            "Yeelight_BLE_ExecGatttool_Aborted",
            $hash
        );
		
        Log3 $name, 4, "Yeelight_BLE ($name) - Write Yeelight_BLE_ExecGatttool_Run $name|$mac|$mod|$handle|$value";
    }
}

sub Yeelight_BLE_ExecGatttool_Run($) {

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

            Log3 $name, 4, "Yeelight_BLE ($name) - ExecGatttool_Run: call gatttool with command: $cmd and loop $loop";

	 		@gtResult = split( "\n", qx($cmd) );

            Log3 $name, 5, "Yeelight_BLE ($name) - ExecGatttool_Run: gatttool loop result ".join( ",", @gtResult );
			
			$debug = join( ",", @gtResult );
            
			$loop++;
			
			if(not defined($gtResult[0])){
				$gtResult[0] = 'connect error';
			}
			else{
				$gtResult[0] = 'connect error' if ($gtResult[0]=~/connect\ error:/ || $gtResult[0]=~/connect:/);
			}
        } while ( $loop < 5 and $gtResult[0] eq 'connect error' );
			
        Log3 $name, 5, "Yeelight_BLE ($name) - ExecGatttool_Run: gatttool result ".join( ",", @gtResult );
		
		my %data_response;
		
		if ($gtResult[0] eq 'connect error') {
			
			$json_notification = encode_json( {'msg' => 'connect error', 'details' => $debug} );
			
		}
		else {			
			foreach my $gtresult_line (@gtResult) {

		        Log3 $name, 5, "Yeelight_BLE ($name) - ExecGatttool_Run: gtresult_line ".$gtresult_line;
				
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

sub Yeelight_BLE_ExecGatttool_Done($) {

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
			CreateParamGatttool( $hash, @$param[0], @$param[1], @$param[2] );	
		}
		#Typically read command
		elsif(scalar @$param == 2) {
			CreateParamGatttool( $hash, @$param[0], @$param[1] );	
		}
		#Unexpected
		else {
		    Log3 $name, 3, "Yeelight_BLE ($name) - ExecGatttool_Done ERROR handling next queued command.";
		}
	}

    Log3 $name, 4, "Yeelight_BLE ($name) - ExecGatttool_Done: Helper is disabled. Stop processing" if ( $hash->{helper}{DISABLED} );
	
    return if ( $hash->{helper}{DISABLED} );

    Log3 $name, 4, "Yeelight_BLE ($name) - ExecGatttool_Done: gatttool return string: $string";

    my $decode_json = decode_json($json_notification);
	
    if ($@) {
        Log3 $name, 3, "Yeelight_BLE ($name) - ExecGatttool_Done: JSON error while request: $@";
    }

	if ( $respstate eq 'ok') {
		
		if($decode_json->{msg} eq 'Notification'){
        	ProcessingNotification( $hash, $gattCmd, $decode_json->{handle}, $decode_json->{value});
		}
		elsif($decode_json->{msg} eq 'Char_Value_Desc'){
			ProcessingCharValueDesc( $hash, $gattCmd, $handle, $decode_json->{value});
		}
	}
    else {
        ProcessingErrors( $hash, $decode_json->{msg});
		
		if($decode_json->{details}){
			Log3 $name, 3, "Yeelight_BLE ($name) - ExecGatttool_Done last gatt error: ".$decode_json->{details};
		}
    }
}

sub Yeelight_BLE_ExecGatttool_Aborted($) {

    my ($hash) = @_;
    my $name = $hash->{NAME};
    my %readings;

    delete( $hash->{helper}{RUNNING_PID} );
	
    readingsSingleUpdate( $hash, "state", "unreachable", 1 );

    $readings{'lastGattError'} =
      'The BlockingCall Process terminated unexpectedly. Timedout';
    WriteReadings( $hash, \%readings );

    Log3 $name, 3, "Yeelight_BLE ($name) - ExecGatttool_Aborted: The BlockingCall Process terminated unexpectedly. Timeout";
}

sub ProcessingNotification($@) {

    my ( $hash, $gattCmd, $handle, $value ) = @_;

    my $name = $hash->{NAME};
	my $model = $hash->{MODEL};
    my $readings;

    Log3 $name, 5, "Yeelight_BLE ($name) - ProcessingNotification: handle: $handle | notification: $value";

    if ( $model eq 'candela' ) {
        if ( $handle eq '0x0022' ) {
            $readings = CandelaHandle0x0022($hash, $value );
        }
    }
    WriteReadings( $hash, $readings );
}

sub ProcessingCharValueDesc($@) {

    my ( $hash, $gattCmd, $handle, $value ) = @_;

    my $name = $hash->{NAME};
	my $model = $hash->{MODEL};
    my $readings;

    Log3 $name, 4, "Yeelight_BLE ($name) - ProcessingCharValueDesc: handle: $handle | value: $value";

    if ( $model eq 'candela' ) {
		if ( $handle eq '0x0003' ) {
            $readings = CandelaHandleStandardGattChar($hash, $value, 'devicename');
        }
        elsif ( $handle eq '0x0009' ) {
            $readings = CandelaHandleStandardGattChar($hash, $value, 'firmware');
        }
        elsif ( $handle eq '0x000b' ) {
            $readings = CandelaHandleStandardGattChar($hash, $value, 'manufacturer');
        }
        elsif ( $handle eq '0x000d' ) {
            $readings = CandelaHandleStandardGattChar($hash, $value, 'model');
        }
    }
    WriteReadings( $hash, $readings );
}

sub CandelaHandle0x0022($$) {
	
    ### Yeelight Candela - Read current state (power, brigthness)
    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 4, "Yeelight_BLE ($name) - Yeelight Candela Handle 0x0022";

    my @dataState = split( " ", $notification );
	
	if ($dataState[0] eq "43" && $dataState[1] eq "45") {
		
		if ($dataState[2] eq "01"){
			
			$readings{'state'} = "on";
			$readings{'pct'} = hex("0x".$dataState[3]);
			
		}
		elsif ($dataState[2] eq "02"){
			
			$readings{'state'} = "off";
			$readings{'pct'} = hex("0x".$dataState[3]);
		}
		else {
			$readings{'state'} = "unknown";
		}
		
	}
	return \%readings;
}

#Handle standard GATT charactaristics
##Device name (UUID 00002a00-0000-1000-8000-00805f9b34fb)
##Firmware revision (UUID 00002a26-0000-1000-8000-00805f9b34fb)
##Manufacturer name string (UUID 00002a29-0000-1000-8000-00805f9b34fb)
##Model ID (UUID 00002a24-0000-1000-8000-00805f9b34fb)
sub CandelaHandleStandardGattChar($@) {
	
    ### Yeelight Candela - Read name
    my ( $hash, $value, $readingname ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 5, "Yeelight_BLE ($name) - Yeelight Candela CandelaHandleStandardGattChar for reading: ".$readingname;
	
	$value =~ s/[^a-fA-F0-9]//g;
		
	$value =~ s/00//g;

	$value =~ s/([a-fA-F0-9]{2})/chr(hex($1))/eg;
	
	$readings{$readingname} = $value;
	
	return \%readings;
}

sub WriteReadings($$) {

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

sub ProcessingErrors($$) {

    my ( $hash, $notification ) = @_;

    my $name = $hash->{NAME};
    my %readings;

    Log3 $name, 5, "Yeelight_BLE ($name) - ProcessingErrors";
	
    $readings{'lastGattError'} = $notification;

    WriteReadings( $hash, \%readings );
}

1;
