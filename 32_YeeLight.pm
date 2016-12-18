##############################################
# $Id: 32_YeeLight.pm 2016-19-12 thaliondrambor $

# TODO
# light functions: timer, schedules
# scenes
# software bridge (UDP): autocreate devices (ID), search for devices,
#						 listening for changes (eg. IP)
# help
# attributes: adjust brightness level

# versions
# 00 start
# 01 added dimup, dimdown, colortemperature, toggle
# 02 changed colortemperature to ct, added hex input for rgb,
#    added attribute defaultramp, added hue and sat
# 03 added reading of notification messages -> no more active reading of bulb status
#    added setting name, added start_cf and stop_cf
#	 added scene (sunrise, sunset, happy_birthday)
#	 added saving default status
# 04 added reopen, added queues for sended commands and received answers to match them 

# verbose level
# 0: quit
# 1: error
# 2: warning
# 3: user command
# 4: 1st technical level (detailed internal reporting)
# 5: 2nd technical level (full internal reporting)
#
# installed CPAN modules: JSON::XS

package main;

use strict;
use warnings;
use POSIX;
use Socket;
use JSON::XS;

sub
YeeLight_Initialize
{
	my ($hash) = @_;
	  
	require "$attr{global}{modpath}/FHEM/DevIo.pm";

	$hash->{ReadFn}			= "YeeLight_Read";
	$hash->{DefFn}			= "YeeLight_Define";
	$hash->{UndefFn}		= "YeeLight_Undef";
	$hash->{ShutdownFn}		= "YeeLight_Shutdown";
	$hash->{SetFn}			= "YeeLight_Set";
	$hash->{AttrFn}			= "YeeLight_Attr";
	$hash->{AttrList}		= 
		"defaultramp "
		." $readingFnAttributes";

	return undef;
}

sub
YeeLight_Define
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def); 
	my $name = $a[0];
	
	return "wrong syntax: define [NAME] YeeLight [IP]" if (@a != 3);
	return "wrong input for IP-address: 'xxx.xxx.xxx.xxx' (0 <= xxx <= 255)" if (!IsValidIP($a[2]));
	
	DevIo_CloseDev($hash);
	
	$hash->{HOST}		= $a[2] if ($a[2]);
    $hash->{PORT}		= 55443;
    $hash->{PROTO}		= 1;
	$hash->{NOTIFYDEV}	= "global";
	
	Log3 $name, 3, "YeeLight $name defined at $hash->{HOST}:$hash->{PORT}";
	
	$attr{$name}{room} = "YeeLight" if(!defined( $attr{$name}{room}));
        
	my $dev = $hash->{HOST}.':'.$hash->{PORT};
	$hash->{DeviceName} = $dev;
	
	YeeLight_GetUpdate($hash);
	
	my @ansQue = ();
	$hash->{helper}->{AnsQue} = \@ansQue;
	
	return undef;
}

sub
YeeLight_Bridge_GetID
{
	my ($hash)	= @_;
	my $curID	= 1;
	$curID		= $data{YeeLightBridge}{msgID} if ($data{YeeLightBridge}{msgID});
	$data{YeeLightBridge}{msgID} = 1 if (!$data{YeeLightBridge}{msgID});
	$data{YeeLightBridge}{msgID} = 1 if ($data{YeeLightBridge}{msgID} >= 9999);
	$data{YeeLightBridge}{msgID}++;
	return $curID;
}

sub
YeeLight_Notify
{
	my ($own_hash,$dev_hash) = @_;
	my $ownName = $own_hash->{NAME};
	return undef if (IsDisabled($ownName));
	
	my $devName = $dev_hash->{NAME};
	my $events = deviceEvents($dev_hash,1);
	return undef if(!$events);
 
	foreach my $event (@{$events})
	{
		if ($devName eq "global" && $event eq "INITIALIZED")
		{
			InternalTimer(gettimeofday() + 1, "YeeLight_GetUpdate", $own_hash);
		}
		elsif ($devName eq $ownName)
		{
			if ($event eq "STATE")
			{
			}
		}
	}
}

sub
YeeLight_GetUpdate
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	Log3 $name, 4, "$name: GetUpdate";
	YeeLight_StatusRequest($hash);
	
	return undef;
}

sub
YeeLight_Shutdown
{
	my ($hash, $arg) = @_;
    my $name = $hash->{NAME};
	
	DevIo_CloseDev($hash);
	RemoveInternalTimer($hash);
	Log3 $name, 5, "YeeLight: shutdown $name";
    
    return undef;
}

sub
YeeLight_Undef
{
	my ($hash, $arg) = @_;
    my $name = $hash->{NAME};
	
	DevIo_CloseDev($hash);
	RemoveInternalTimer($hash);
	Log3 $name, 3, "YeeLight: undefined $name";
    
    return undef;
}

sub
YeeLight_Set
{
    
    my ($hash, $name, $cmd, @val) = @_;
    
	my $list = "";
	$list .= "on ";
	$list .= "off ";
	$list .= "toggle ";
	$list .= "hsv ";
	$list .= "hue ";
	$list .= "sat ";
	$list .= "rgb ";
	$list .= "bright ";
	$list .= "dimup ";
	$list .= "dimdown ";
	$list .= "color ";
	$list .= "ct ";
	$list .= "start_cf ";
	$list .= "stop_cf ";
	$list .= "scene ";
	$list .= "name ";
	$list .= "default:noArg ";
	$list .= "reopen:noArg ";
	$list .= "statusrequest:noArg ";

	if (lc $cmd eq 'on'
		|| lc $cmd eq 'off'
		|| lc $cmd eq 'toggle'
		|| lc $cmd eq 'hsv'
		|| lc $cmd eq 'hue'
		|| lc $cmd eq 'sat'
		|| lc $cmd eq 'rgb'
		|| lc $cmd eq 'bright'
		|| lc $cmd eq 'dimup'
		|| lc $cmd eq 'dimdown'
		|| lc $cmd eq 'color'
		|| lc $cmd eq 'ct'
		|| lc $cmd eq 'start_cf'
		|| lc $cmd eq 'stop_cf'
		|| lc $cmd eq 'scene'		
		|| lc $cmd eq 'name'
		|| lc $cmd eq 'default'
		|| lc $cmd eq 'reopen'
		|| lc $cmd eq 'statusrequest')
	{
	    Log3 $name, 3, "YeeLight $name - set $name $cmd ".join(" ", @val);
		if (@val
			|| lc $cmd eq 'statusrequest'
			|| lc $cmd eq "on"
			|| lc $cmd eq "off"
			|| lc $cmd eq "dimup"
			|| lc $cmd eq "dimdown"
			|| lc $cmd eq "toggle"
			|| lc $cmd eq "default"
			|| lc $cmd eq "reopen"
			|| lc $cmd eq "stop_cf")
		{
			return YeeLight_SelectSetCmd($hash, $cmd, @val);
		}
	}

	return "Unknown argument $cmd, bearword as argument or wrong parameter(s), choose one of $list";
}

sub
YeeLight_SelectSetCmd
{
	my ($hash, $cmd, @args) = @_;
	my $descriptor = '';
	my $name = $hash->{NAME};
  
	# remove descriptor from @args
	for (my $i = $#args; $i >= 0; --$i )
	{
		if ($args[$i] =~ /\/d\:(.*)/)
		{
			$descriptor = $1;
			splice (@args, $i, 1);
		}
	}
  
	my $cnt = @args;

	if (lc $cmd eq 'on' || $cmd eq 'off')
	{
		my $sCmd;
		$sCmd->{'method'}		= "set_power";							# method:set_power
		$sCmd->{'params'}->[0]	= $cmd;									# on/off
		$sCmd->{'params'}->[2]	= $args[0] if ($args[0]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,2);
	}
	
	elsif (lc $cmd eq "hsv")
	{
		return "usage: set $name $cmd [hue] [saturation]" if !(($cnt == 2) || ($cnt == 3)) || ($args[0] !~ /^\d?.?\d+$/) || ($args[1] !~ /^\d?.?\d+$/);
		return "choose hue between 0 and 359" if ($args[0] < 0) || ($args[0] > 359);
		return "choose saturation between 0 and 100" if ($args[1] < 0) || ($args[1] > 100);
		
		my $sCmd;
		$sCmd->{'method'}		= "set_hsv";							# method:set_hsv
		$sCmd->{'params'}->[0]	= int($args[0]);						# hue
		$sCmd->{'params'}->[1]	= int($args[1]);						# saturation
		$sCmd->{'params'}->[3]	= $args[2] if ($args[2]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,3);
	}
	
	elsif (lc $cmd eq "hue")
	{
		return "usage: set $name $cmd [hue]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose hue between 0 and 359" if ($args[0] < 0) || ($args[0] > 359);
		
		my $sCmd;
		$sCmd->{'method'}		= "set_hsv";							# method:set_hsv
		$sCmd->{'params'}->[0]	= int($args[0]);						# hue
		$sCmd->{'params'}->[1]	= $hash->{READINGS}{saturation}{VAL} + 0;# saturation
		$sCmd->{'params'}->[3]	= $args[1] if ($args[1]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,3);
	}
	
	elsif (lc $cmd eq "sat")
	{
		return "usage: set $name $cmd [saturation]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose hue between 0 and 100" if ($args[0] < 0) || ($args[0] > 359);

		my $sCmd;
		$sCmd->{'method'}		= "set_hsv";							# method:set_hsv
		$sCmd->{'params'}->[0]	= $hash->{READINGS}{hue}{VAL} + 0;		# hue
		$sCmd->{'params'}->[1]	= int($args[0]);						# saturation
		$sCmd->{'params'}->[3]	= $args[1] if ($args[1]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,3);
	}
	
	elsif (lc $cmd eq "statusrequest")
	{
		YeeLight_StatusRequest($hash);
	}
	
	elsif (lc $cmd eq "rgb")
	{
		my $sCmd;
		my $rgb		= undef;

		if (defined($args[0]) && $args[0] =~ /^[0-9A-Fa-f]{6}$/)
		{
			$rgb	= "FFFFFF" if ($rgb eq "000000");
			$rgb	= hex($args[0]);
			$sCmd->{'params'}->[2] = $args[1] if ($args[1]);			# ramp time
		}
		elsif((($cnt == 3) || ($cnt == 4)) && ($args[0] =~ /^\d?.?\d+$/) && ($args[1] =~ /^\d?.?\d+$/) && ($args[2] =~ /^\d?.?\d+$/))
		{
			return "choose color (red, green, blue) between 0 and 255" if ($args[0] < 0) || ($args[0] > 255) || ($args[1] < 0) || ($args[1] > 255) || ($args[2] < 0) || ($args[2] > 255);
			my $r	= int($args[0]);
			my $g	= int($args[1]);
			my $b	= int($args[2]);
			$rgb	= ($r * 256 * 256) + ($g * 256) + $b;
			$rgb	= (255 * 256 * 256) + (255 * 256) + 255 if ($rgb == 0);
			$sCmd->{'params'}->[2] = $args[3] if ($args[3]);			# ramp time
		}
		else
		{
			return "usage: set $name $cmd [red] [green] [blue] or set $name $cmd RRGGBB";
		}
		
		$sCmd->{'method'}		= "set_rgb";							# method:set_rgb
		$sCmd->{'params'}->[0]	= $rgb;									# rgb

		YeeLight_SendCmd($hash,$sCmd,$cmd,2);
	}

	elsif (lc $cmd eq "bright")
	{
		return "usage: set $name $cmd [brightness]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose brightness between 0 and 100" if ($args[0] < 0) || ($args[0] > 100);
		
		my $sCmd;
		if ($args[0] == 0)
		{
			$sCmd->{'method'}		= "set_power";							# method:set_power
			$sCmd->{'params'}->[0]	= "off";								# on
			$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);				# ramp time
		}
		else
		{
			$sCmd->{'method'}		= "set_bright";							# method:set_bright
			$sCmd->{'params'}->[0]	= int($args[0]);						# brightness
			$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);				# ramp time
		}
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,2);
	}
	
	elsif (lc $cmd eq "color")
	{
			my %color = (
			"red"			=> "255,0,0",		"rot"			=> "255,0,0",
			"yellow"		=> "255,255,0",		"gelb"			=> "255,255,0",
			"white"			=> "255,255,255",	"weiß"			=> "255,255,255",
			"green"			=> "0,255,0",		"grün"			=> "0,255,0",
			"cyan"			=> "0,255,255",
			"blue"			=> "0,0,255",		"blau"			=> "0,0,255",
			"magenta"		=> "255,0,255",
			"orange"		=> "254,127,0",
			"violett"		=> "140,0,254",
			"bluegreen"		=> "0,254,127",		"blaugrün"		=> "0,254,127",
			"greenblue"		=> "0,127,254",		"grünblau"		=> "0,127,254",
			"greenyellow"	=> "127,254,0",		"grüngelb"		=> "127,254,0",
			"bluered"		=> "254,0,127",		"blaurot"		=> "254,0,127",
			"vermilion"		=> "252,63,0",		"zinnober"		=> "252,63,0",
			"indigo"		=> "63,0,252",
			"bluecyan"		=> "0,189,252",		"blaucyan"		=> "0,189,252",
			"redmagenta"	=> "252,0,189",		"rotmagenta"	=> "252,0,189",
			"safran"		=> "252,189,0",
			"bluemagenta"	=> "189,0,252",		"blaumagenta"	=> "189,0,252",
			"greencyan"		=> "0,252,189",		"grüncyan"		=> "0,252,189",
			"limett"		=> "63,252,0",
			"brown"			=> "216,108,54",	"braun"			=> "216,108,54",
		);

		if (!$color{lc($args[0])})
		{
			my @colorKeys	= keys(%color);
			my $keys		= join(', ',@colorKeys);
			return "Unknown color. Choose from: $keys";
		}
		my @rgb = split(/\,/,$color{lc($args[0])});
		my $setColor = ($rgb[0] * 256 *256) + ($rgb[1] * 256) + $rgb[2];
				
		my $sCmd;
		$sCmd->{'method'}		= "set_rgb";							# method:set_hsv
		$sCmd->{'params'}->[0]	= $setColor;							# color in rgb
		$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,2);
	}
	
	elsif ($cmd eq 'dimup' || $cmd eq 'dimdown')
	{
		if ($cnt == 0)
		{
			my $sCmd;
			$sCmd->{'method'}		= "set_adjust";						# method:set_adjust
			$sCmd->{'params'}->[0]	= "increase" if ($cmd eq "dimup");	# dimup
			$sCmd->{'params'}->[0]	= "decrease" if ($cmd eq "dimdown");# dimdown
			$sCmd->{'params'}->[1]	= "bright";							# brightness
			
			YeeLight_SendCmd($hash,$sCmd,$cmd,2);
		}
		elsif ($cnt == 2 || $cnt == 1)
		{		
			my $oldBright = $hash->{READINGS}{brightness}{VAL};
			$args[0] = $oldBright + $args[0] if ($cmd eq "dimup");
			$args[0] = $oldBright - $args[0] if ($cmd eq "dimdown");
			$args[0] = 0 if ($args[0] < 0);
			$args[0] = 100 if ($args[0] > 100);
		
			YeeLight_SelectSetCmd($hash,'bright',@args);
		}
		else
		{
			return "usage: set $name $cmd [dimup/dimdown] <VALUE>";
		}
	}
	
	elsif (lc $cmd eq "ct")
	{
		return "usage: set $name $cmd [COLORTEMPERATUR]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose color temperature between 1700 and 6500" if ($args[0] < 1700) || ($args[0] > 6500);
		
		my $sCmd;
		$sCmd->{'method'}		= "set_ct_abx";							# method:set_ct_abx
		$sCmd->{'params'}->[0]	= int($args[0]);						# color temperature
		$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,2);
	}
	
	elsif (lc $cmd eq "toggle")
	{
		my $power = $hash->{READINGS}{power}{VAL};
		YeeLight_SelectSetCmd($hash,"on",@args) if ($power eq "off");
		YeeLight_SelectSetCmd($hash,"off",@args) if ($power eq "on");
	}
	
	elsif (lc $cmd eq "name")
	{
		return "usage: set $name $cmd [NAME]" if ($cnt != 1);
		
		my $sCmd;
		$sCmd->{'method'}		= "set_name";							# method:set_name
		$sCmd->{'params'}->[0]	= $args[0];								# name
		
		YeeLight_SendCmd($hash,$sCmd,$cmd);
	}
	
	elsif (lc $cmd eq "default")
	{
		return "$name: Bulb needs to be on, for saving the state." if ($hash->{READINGS}{power}{VAL} ne "on");
		return "usage: set $name $cmd" if ($cnt != 0);
			
		my $sCmd;
		$sCmd->{'method'}		= "set_default";						# method:set_default
		$sCmd->{'params'}->[0]	= "";									# no parameter
		
		YeeLight_SendCmd($hash,$sCmd,$cmd);
	}
	
	elsif (lc $cmd eq "scene")
	{
		if ($args[0] ne "sunset"
			&& $args[0] ne "sunrise"
			&& $args[0] ne "happy_birthday")
		{
			my $sceneList;
			$sceneList .= "sunrise ";
			$sceneList .= "sunset ";
			$sceneList .= "happy_birthday ";
			return "Unknown scene. Choose from: $sceneList";
		}
		
		my %scene;
		$scene{sunset}{type}			= "start_cf";
		$scene{sunset}{count}			= "3";
		$scene{sunset}{action}			= "2";
		$scene{sunset}{val}				= "50,2,2700,10,180000,2,1700,5,420000,1,16731136,1";
		$scene{sunrise}{type}			= "start_cf";
		$scene{sunrise}{count}			= "3";
		$scene{sunrise}{action}			= "1";
		$scene{sunrise}{val}			= "50,1,16731136,1,360000,2,1700,10,540000,2,2700,100";
		$scene{happy_birthday}{type}	= "start_cf";
		$scene{happy_birthday}{count}	= "0";
		$scene{happy_birthday}{action}	= "1";
		$scene{happy_birthday}{val}		= "2000,1,14438425,80,2000,1,14448670,80,2000,1,11153940,80";

		my @newArgs;
		
		if ($scene{$args[0]}{type} eq "start_cf")
		{
			push(@newArgs,$scene{$args[0]}{count});
			push(@newArgs,$scene{$args[0]}{action});
			push(@newArgs,$scene{$args[0]}{val});
		}
		
		YeeLight_SelectSetCmd($hash,$scene{$args[0]}{type},@newArgs);
	}
	
	elsif (lc $cmd eq "start_cf")
	{
		return "$name start_cf: count ($args[0]) must be numeric." if ($args[0] !~ /^\d?.?\d+$/);
		return "$name start_cf: action ($args[1]) must be numeric." if ($args[1] !~ /^\d?.?\d+$/);
		return "$name start_cf: action ($args[1]) must be 1, 2 or 3." if ($args[1] < 1) || ($args[1] > 3);
		my $sCmd;
		$sCmd->{'method'}		= "start_cf";							# method:start_cf
		$sCmd->{'params'}->[0]	= $args[0] + 0;							# count
		$sCmd->{'params'}->[1]	= $args[1] + 0;							# action
		$sCmd->{'params'}->[2]	= $args[2];								# color flow tuples
		
		YeeLight_SendCmd($hash,$sCmd,$cmd);
	}
	
	elsif (lc $cmd eq "stop_cf")
	{
		my $sCmd;
		$sCmd->{'method'}		= "stop_cf";							# method:stop_cf
		$sCmd->{'params'}->[0]	= "";									# no parameter
		
		YeeLight_SendCmd($hash,$sCmd,$cmd);
	}
	
	elsif (lc $cmd eq "reopen")
	{
		DevIo_CloseDev($hash);
		DevIo_OpenDev($hash, 0,, sub(){
			my ($hash, $err) = @_;
			Log3 $name, 2, "$name: $err" if($err);
		});
		Log3 $name, 3, "$name: reconnected.";
	}
	
	# TODO
	
	#timer
	#schedules
	
	return undef;
}

sub
YeeLight_SendCmd
{
	my ($hash,$sCmd,$cmd,$rCnt) = @_;
	my $name	= $hash->{NAME};
	my $error	= undef;
	
	if (lc $cmd eq "name" || lc $cmd eq "default" || lc $cmd eq "start_cf" || lc $cmd eq "stop_cf") {}
	elsif (defined($sCmd->{'params'}->[$rCnt]))
	{
		$error = "usage: set $name $cmd [milliseconds]" if $sCmd->{'params'}->[$rCnt] !~ /^\d?.?\d+$/;
		$error = "minimum for milliseconds is 30" if $sCmd->{'params'}->[$rCnt] < 30;
		Log3 $name, 4, "$name: $error" if (defined $error);
		return $error if (defined $error);
		$sCmd->{'params'}->[$rCnt - 1] = "smooth";						# flow
		$sCmd->{'params'}->[$rCnt] += 0;								# force ramp time to be int
	}
	elsif (defined($attr{$name}{defaultramp}))
	{
		$sCmd->{'params'}->[$rCnt - 1] = "smooth";						# flow
		$sCmd->{'params'}->[$rCnt] = $attr{$name}{defaultramp} + 0;		# force default ramp time to be int
	}
	elsif ($sCmd->{'method'} eq "set_ct_abx")
	{

		$sCmd->{'params'}->[$rCnt - 1] = "sudden";						# no flow
		$sCmd->{'params'}->[$rCnt] = 0;									# no flow
	}
	
	YeeLight_IsOn($hash) if (lc $cmd ne "statusrequest") && (lc $cmd ne "on") && (lc $cmd ne "off") && (lc $cmd ne "toggle") && (lc $cmd ne "name");
	
	$sCmd->{'id'}	= YeeLight_Bridge_GetID($hash);
	my $send		= encode_json($sCmd);
	Add_SendQue($hash,$sCmd->{'id'},$send);
	$send			.= "\r\n";
	$send			= qq($send);
		
	DevIo_OpenDev($hash, 0,, sub(){
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
	}) if ($hash->{STATE} ne "opened");
	DevIo_SimpleWrite($hash, $send, 2);
	Log3 $name, 4, "$name is sending: $send";

	return undef;
}

sub
YeeLight_StatusRequest
{
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $msgID	= YeeLight_Bridge_GetID($hash);
	my $send	= '{"id":'.$msgID.',"method":"get_prop","params":["power","bright","ct","rgb","hue","sat","color_mode","flowing","delayoff","flow_params","music_on","name"]}';
	Add_SendQue($hash,$msgID,$send);
	$send		.= "\r\n";
	$send		= qq($send);
	
	DevIo_OpenDev($hash, 0,, sub(){ 
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
	}) if ($hash->{STATE} ne "opened");
	DevIo_SimpleWrite($hash, $send, 2);
	Log3 $name, 4, "$name is sending $send";
	
	return undef;
}

sub
YeeLight_Read
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	my $buf = DevIo_SimpleRead($hash);
	return undef if(!defined($buf));
	
	my $read;
	my $search = "}";
	my $offset = 0;
	my $result = index($buf, $search, $offset);
	
	while ($result != -1)
	{
		my $sResult = index($buf, "}}", $offset);
		$result++ if ($result == $sResult);
		$result++;
		$read = substr($buf,$offset,$result);
		Log3 $name, 4, "reading from $name: $read";
	
		Add_AnsQue($hash,$read);
		$offset = $result + 1;
		$result = index($buf, $search, $offset);
	}
	
	return undef;
}

sub
Add_SendQue
{
	my ($hash,$id,$send) = @_;
	my $name = $hash->{NAME};
	
	$hash->{helper}->{SendQue}->{$id} = $send;
	Log3 $name, 5, "Added $hash->{helper}->{SendQue}->{$id} with id:$id to SendQueue of $name.";
	
	return undef;
}

sub
Add_AnsQue
{
	my ($hash,$ans) = @_;
	my $name = $hash->{NAME};
	
	push(@{$hash->{helper}->{AnsQue}},$ans);
	my $length = @{$hash->{helper}->{AnsQue}};
	Log3 $name, 5, "Added $hash->{helper}->{AnsQue}[($length - 1)] to AnswerQueue of $name.";
	
	Do_AnsQue($hash);
	
	return undef;
}

sub
Do_AnsQue
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $i = 0;
	
	foreach my $ans (@{$hash->{helper}->{AnsQue}})
	{
		my $jsonAns = decode_json($ans);
		if (defined($jsonAns->{'method'}) && $jsonAns->{'method'} eq "props")
		{
			Log3 $name, 4, "Detected notification broadcast from $name: $ans.";
			YeeLight_Parse($hash,$jsonAns);
			Log3 $name, 5, "Deleted $ans from AnswerQueue of $name.";
			splice(@{$hash->{helper}->{AnsQue}}, $i, 1);
		}
		elsif (defined($jsonAns->{'id'}))
		{
			if (defined($hash->{helper}->{SendQue}->{$jsonAns->{'id'}}))
			{
				my $send = $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
				my $jsonSend = decode_json($send);
				if ((defined($jsonAns->{'result'})) && ($jsonAns->{'result'}->[0] eq "ok"))
				{
					Log3 $name, 3, "$name success sending $jsonSend->{'id'}: $send";
					Log3 $name, 5, "Deleted $send from SendQueue of $name.";
					delete $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
				}
				elsif ($ans =~ /error/)
				{
					Log3 $name, 1, "$name error sending $jsonSend->{'id'}: $send";
					Log3 $name, 5, "Deleted $send from SendQueue of $name.";
					delete $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
				}
				elsif (defined($jsonAns->{'result'}) && defined($jsonAns->{'result'}->[11]))
				{
					YeeLight_ParseStatusRequest($hash,$jsonAns);
					Log3 $name, 5, "Deleted $send from SendQueue of $name.";
					delete $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
				}
				else
				{
					Log3 $name, 1, "Couldn't match answer ($ans) with SendQueue of $name.";
				}
				
				Log3 $name, 5, "Deleted $ans from AnswerQueue.";
				splice(@{$hash->{helper}->{AnsQue}}, $i, 1);
			}
		}
		
		$i++;
	}
	
	return undef;
}

sub
YeeLight_Parse
{
	my ($hash,$json) = @_;
	my $name = $hash->{NAME};
	
	my $rgb		= undef;
	my $hexrgb	= undef;
	my $b		= undef;
	my $g		= undef;
	my $r		= undef;
	
	if (defined($json->{'params'}->{'rgb'}))
	{
		$rgb	= $json->{'params'}->{'rgb'};
		$hexrgb	= sprintf("%06X",$rgb);
		$b		= $rgb % 256;
		$g		= (($rgb - $b) / 256) % 256;
		$r		= ($rgb - $b - ($g * 256)) / (256 * 256);
	}
	
	my $colormode	= undef;
	my $colorflow	= undef;
	my $musicmode	= undef;
	
	if (defined($json->{'params'}->{'color_mode'}))
	{
		$colormode	= "RGB"					if ($json->{'params'}->{'color_mode'} eq 1);
		$colormode	= "color temperature"	if ($json->{'params'}->{'color_mode'} eq 2);
		$colormode	= "HSV" 				if ($json->{'params'}->{'color_mode'} eq 3);
	}
	if (defined($json->{'params'}->{'flowing'}))
	{
		$colorflow	= "off"					if ($json->{'params'}->{'flowing'} eq 0);
		$colorflow	= "on"					if ($json->{'params'}->{'flowing'} eq 1);
	}
	if (defined($json->{'params'}->{'music_on'}))
	{
		$musicmode	= "off"					if ($json->{'params'}->{'music_on'} eq 0);
		$musicmode	= "on"					if ($json->{'params'}->{'music_on'} eq 1);
	}
	
	readingsBeginUpdate($hash);
		readingsBulkUpdate($hash,"power",$json->{'params'}->{'power'})				if defined($json->{'params'}->{'power'});
		readingsBulkUpdate($hash,"bright",$json->{'params'}->{'bright'})			if defined($json->{'params'}->{'bright'});
		readingsBulkUpdate($hash,"ct",$json->{'params'}->{'ct'})					if defined($json->{'params'}->{'ct'});
		readingsBulkUpdate($hash,"rgb",$hexrgb)										if defined($hexrgb);
		readingsBulkUpdate($hash,"rgb_blue",$b)										if defined($b);	
		readingsBulkUpdate($hash,"rgb_green",$g)									if defined($g);
		readingsBulkUpdate($hash,"rgb_red",$r)										if defined($r);
		readingsBulkUpdate($hash,"hue",$json->{'params'}->{'hue'})					if defined($json->{'params'}->{'hue'});
		readingsBulkUpdate($hash,"sat",$json->{'params'}->{'sat'})					if defined($json->{'params'}->{'sat'});
		readingsBulkUpdate($hash,"color_mode",$colormode)							if defined($colormode);
		readingsBulkUpdate($hash,"color_flow",$colorflow)							if defined($colorflow);
		readingsBulkUpdate($hash,"sleeptimer",$json->{'params'}->{'delayoff'})		if defined($json->{'params'}->{'delayoff'});
		readingsBulkUpdate($hash,"flow_params",$json->{'params'}->{'flow_params'})	if defined($json->{'params'}->{'flow_params'});
		readingsBulkUpdate($hash,"music_mode",$musicmode)							if defined($musicmode);
		readingsBulkUpdate($hash,"name",$json->{'params'}->{'name'})				if defined($json->{'params'}->{'name'});
	readingsEndUpdate($hash,1);
	
	Log3 $name, 3, "$name updated readings.";

	return undef;
}

sub
YeeLight_ParseStatusRequest
{
	my ($hash,$answer)	= @_;
	my $name = $hash->{NAME};

	my $rgb		= $answer->{'result'}->[3];
	my $hexrgb	= sprintf("%06X",$rgb);
	my $b		= $rgb % 256;
	my $g		= (($rgb - $b) / 256) % 256;
	my $r		= ($rgb - $b - ($g * 256)) / (256 * 256);
	my $colormode;
	my $colorflow;
	my $musicmode;
	$colormode	= "RGB"					if ($answer->{'result'}->[6] eq 1);
	$colormode	= "color temperature"	if ($answer->{'result'}->[6] eq 2);
	$colormode	= "HSV" 				if ($answer->{'result'}->[6] eq 3);
	$colorflow	= "off"					if ($answer->{'result'}->[7] eq 0);
	$colorflow	= "on"					if ($answer->{'result'}->[7] eq 1);
	$musicmode	= "off"					if ($answer->{'result'}->[10] eq 0);
	$musicmode	= "on"					if ($answer->{'result'}->[10] eq 1);
	
	if ($answer)
	{
		readingsBeginUpdate($hash);
			readingsBulkUpdate($hash,"power",$answer->{'result'}->[0]);
			readingsBulkUpdate($hash,"bright",$answer->{'result'}->[1]);
			readingsBulkUpdate($hash,"ct",$answer->{'result'}->[2]);
			readingsBulkUpdate($hash,"rgb",$hexrgb);
			readingsBulkUpdate($hash,"rgb_blue",$b);
			readingsBulkUpdate($hash,"rgb_green",$g);
			readingsBulkUpdate($hash,"rgb_red",$r);
			readingsBulkUpdate($hash,"hue",$answer->{'result'}->[4]);
			readingsBulkUpdate($hash,"sat",$answer->{'result'}->[5]);
			readingsBulkUpdate($hash,"color_mode",$colormode);
			readingsBulkUpdate($hash,"color_flow",$colorflow);
			readingsBulkUpdate($hash,"sleeptimer",$answer->{'result'}->[8]);
			readingsBulkUpdate($hash,"flow_params",$answer->{'result'}->[9]);
			readingsBulkUpdate($hash,"music_mode",$musicmode);
			readingsBulkUpdate($hash,"name",$answer->{'result'}->[11]);
		readingsEndUpdate($hash,1);
		
		Log3 $name, 3, "$name full statusrequest";
	}
	
	return undef;
}

sub
YeeLight_Get
{
  return undef;
}

sub
YeeLight_Attr
{
	my ($cmd,$name,$attrName,$attrVal) = @_;
	
	if ($cmd eq "set")
	{
		if ($attrName eq "defaultramp")
		{
			return "Invalid parameter for $attrName. $attrName must be numeric and more than 30." if ($attrVal !~ /^\d?.?\d+$/) || ($attrVal < 30);
		}
	}
	
	return undef;
}

sub
YeeLight_Init
{
	return undef;
}

sub
YeeLight_IsOn
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	YeeLight_SelectSetCmd($hash,"on") if ($hash->{READINGS}{power}{VAL} eq "off");
	return undef;
}

# helper subroutines

sub
IsValidIP
{
	return $_[0] =~ /^[\d\.]*$/ && inet_aton($_[0]);
}

1;