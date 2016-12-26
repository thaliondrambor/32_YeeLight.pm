##############################################
# $Id: 32_YeeLight.pm 2016-12-26 thaliondrambor $

##### special thanks to herrmannj for permission to use code from 32_WifiLight.pm
##### currently in use: WifiLight_HSV2RGB
#####
##### also thanks to f-zappa for testing and reporting bugs

# TODO
# light functions: timer, schedules
# scenes
# software bridge (UDP): search request

# help
# attributes: adjust brightness level

# versions
# 00 start
# 01 added dimup, dimdown, colortemperature, toggle
# 02 changed colortemperature to ct, added hex input for rgb,
#	 added attribute defaultramp, added hue and sat
# 03 added reading of notification messages -> no more active reading of bulb status
#    added setting name, added start_cf and stop_cf
#	 added scene (sunrise, sunset, happy_birthday)
#	 added saving default status
# 04 added reopen, added queues for sended commands and received answers to match them 
# 05 improved control of parameters for colorflow
# 06 fixed a bug with reading answers, when 2 or more arrive at the same time
#	 strings are evaluated before de-/encoding, so that no more crashes should occure
#	 because of invalid json strings
#	 added queue for errors
#	 added commands raw and flush
# 07 small bugfix, changed "rgb 000000" to "off"
# 08 added blink
# 09 added software bridge support
# 10 added timeout, keepAlive, SetExtensions (on-for-timer, off-for-timer, intervals)
#    bugfixes
# 11 bugfix for ramp = 0 with defaultramp set
#    bugfix for bug with scene command

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
use SetExtensions;

sub
YeeLight_Initialize
{
	my ($hash) = @_;
	  
	require "$attr{global}{modpath}/FHEM/DevIo.pm";

	$hash->{ReadFn}			= "YeeLight_Read";
	$hash->{NotifyFn}		= "YeeLight_Notify";
	$hash->{DefFn}			= "YeeLight_Define";
	$hash->{UndefFn}		= "YeeLight_Undef";
	$hash->{ShutdownFn}		= "YeeLight_Shutdown";
	$hash->{SetFn}			= "YeeLight_Set";
	$hash->{ReadyFn}		= "YeeLight_Ready";
	$hash->{AttrFn}			= "YeeLight_Attr";
	$hash->{AttrList}		= ""
		."defaultramp "
		."updateIP:0,1 "
		."timeout "
		."keepAlive "
		."$readingFnAttributes";
	
	# Comm from Bridge
	$hash->{Match}			= "^.*";
	
	$hash->{ParseFn}		= "YeeLightBridge_Parse";

	return undef;
}

sub
YeeLight_Define
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def); 
	my $name = $a[0];
	
	return "wrong syntax: define [NAME] YeeLight [IP]" if (@a != 3 ) && (@a != 4);
	return "wrong input for IP-address: 'xxx.xxx.xxx.xxx' (0 <= xxx <= 255)" if (!IsValidIP($a[2]));
	
	DevIo_CloseDev($hash);
	
	$hash->{NAME} 				= $name;
	$hash->{HOST}				= $a[2];
    $hash->{PORT}				= 55443;
    $hash->{PROTO}				= 1;
	$hash->{NOTIFYDEV}			= "global";
	$hash->{ID}					= $a[2] if (!$a[3]);
	$hash->{ID}					= $a[3] if ($a[3]);
	
	Log3 $name, 3, "YeeLight $name defined at $hash->{HOST}:$hash->{PORT}";
	
	$attr{$name}{room} = "YeeLight" if !defined( $attr{$name}{room});
        
	my $dev = $hash->{HOST}.':'.$hash->{PORT};
	$hash->{DeviceName} = $dev;
	$hash->{DEF}		= $hash->{HOST};
	
	DevIo_OpenDev($hash, 0,, sub(){ 
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
		return "$err" if($err);
	});
	
	YeeLight_GetUpdate($hash);
	
	my @ansQue = ();
	$hash->{helper}->{AnsQue} = \@ansQue;
	
	my @errQue = ();
	$hash->{helper}->{ErrQue} = \@errQue;
	
	my %sendQue;
	$hash->{helper}->{SendQue} = \%sendQue;
	
	$modules{YeeLight}{defptr}{$hash->{ID}} = $hash;
	
	return undef;
}

sub
YeeLight_Bridge_GetID
{
	my ($hash)	= @_;
	my $curID	= 1;
	$curID		= $data{YeeLightBridge}{msgID} if ($data{YeeLightBridge}{msgID});
	$data{YeeLightBridge}{msgID} = 1 if !defined($data{YeeLightBridge}{msgID});
	$data{YeeLightBridge}{msgID} = 1 if defined($data{YeeLightBridge}{msgID} >= 9999);
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
		elsif ($devName eq "global" && $event =~ /^DELETEATTR $ownName keepAlive/)
		{
			RemoveInternalTimer($own_hash,"YeeLight_GetUpdate");
			Log3 $ownName, 3, "$ownName: stopped sending periodic status requests.";
		}
		elsif ($devName eq "global" && $event =~ /^ATTR $ownName keepAlive/ )
		{
			YeeLight_GetUpdate($own_hash);
			Log3 $ownName, 3, "$ownName: started sending periodic status requests.";
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
	
	my $bHash = $modules{YeeLightBridge}{defptr};
	my $bName = $bHash->{NAME};
	my $keepAlive	= 0;
	$keepAlive		= $attr{$bName}{keepAlive} if defined($attr{$bName}{keepAlive});
	$keepAlive		= $attr{$name}{keepAlive} if defined($attr{$name}{keepAlive});
	
	if ($keepAlive != 0)
	{
		InternalTimer(gettimeofday() + $keepAlive,"YeeLight_GetUpdate",$hash);
	}
	
	return undef;
}

sub
YeeLight_Shutdown
{
	my ($hash, $arg) = @_;
    my $name = $hash->{NAME};
	
	Log3 $name, 4, "$name: shutdown $name";
	DevIo_CloseDev($hash);
	RemoveInternalTimer($hash);
	
	Log3 $name, 4, "$name: do flush because of shutdown";
	YeeLight_Flush($hash);
    
    return undef;
}

sub
YeeLight_Undef
{
	my ($hash, $arg) = @_;
    my $name = $hash->{NAME};
	my $id = $hash->{ID};

	Log3 $name, 3, "YeeLight: undefined $name";
	DevIo_CloseDev($hash);
	RemoveInternalTimer($hash);
	
	Log3 $name, 4, "$name: do flush because of undefine";
	YeeLight_Flush($hash);
	
	delete($modules{YeeLight}{defptr}{$id}) if (defined($modules{YeeLight}{defptr}{$id}));
    
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
	$list .= "on-for-timer ";
	$list .= "off-for-timer ";
	$list .= "intervals ";
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
	$list .= "blink ";
	$list .= "name ";
	$list .= "default:noArg ";
	$list .= "reopen:noArg ";
	$list .= "statusrequest:noArg ";
	
	if (lc $cmd eq 'on'
		|| lc $cmd eq 'off'
		|| lc $cmd eq 'toggle'
		|| lc $cmd eq 'on-for-timer'
		|| lc $cmd eq 'off-for-timer'
		|| lc $cmd eq 'intervals'
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
		|| lc $cmd eq 'blink'
		|| lc $cmd eq 'default'
		|| lc $cmd eq 'reopen'
		|| lc $cmd eq 'statusrequest'
		|| lc $cmd eq 'raw'
		|| lc $cmd eq 'flush')
	{
	    Log3 $name, 3, "YeeLight $name - set $name $cmd ".join(" ", @val);
		return YeeLight_SelectSetCmd($hash, $list, $cmd, @val);
	}

	return "Unknown argument $cmd, bearword as argument or wrong parameter(s), choose one of $list";
}

sub
YeeLight_SelectSetCmd
{
	my ($hash, $list, $cmd, @args) = @_;
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
	
	if ($hash->{STATE} ne "opened" && lc $cmd ne 'reopen')
	{
		Log3 $name, 3, "$name can't send $cmd ".join(" ", @args)." with state \"$hash->{STATE}".
		return "Can't send command if bulb is not connected. Try \"reopen\" and check, if bulb is powered. Current state is $hash->{STATE}";
	}
  
	my $cnt = @args;

	if (lc $cmd eq 'on' || $cmd eq 'off')
	{
		my $sCmd;
		$sCmd->{'method'}		= "set_power";							# method:set_power
		$sCmd->{'params'}->[0]	= $cmd;									# on/off
		$sCmd->{'params'}->[2]	= $args[0] if (defined($args[0]));		# ramp time
		
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
		$sCmd->{'params'}->[1]	= $hash->{READINGS}{sat}{VAL} + 0;		# saturation
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

		if ((@args == 1 || @args == 2) && $args[0] eq "000000")
		{
			$sCmd->{'method'}		= "set_power";
			$sCmd->{'params'}->[0]	= "off";
			$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);
			
			YeeLight_SendCmd($hash,$sCmd,$cmd,2);
		}
		elsif ($args[0] == 0 && $args[1] == 0 && $args[2] == 0 && (@args == 3 || @args == 4))
		{
			$sCmd->{'method'}		= "set_power";
			$sCmd->{'params'}->[0]	= "off";
			$sCmd->{'params'}->[2]	= $args[3] if ($args[3]);
			
			YeeLight_SendCmd($hash,$sCmd,$cmd,2);
		}
		else
		{
			if (defined($args[0]) && $args[0] =~ /^[0-9A-Fa-f]{6}$/)
			{
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
			
			YeeLight_SendCmd($hash,$sCmd,$cmd);
		}
		elsif ($cnt == 2 || $cnt == 1)
		{		
			my $oldBright = $hash->{READINGS}{bright}{VAL};
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
		
		YeeLight_SelectSetCmd($hash,$list,$scene{$args[0]}{type},@newArgs);
	}
	
	elsif (lc $cmd eq "start_cf")
	{
		return "usage: set $name $cmd [count] [action] [flowparams]" if ($cnt != 3);
		return "$name $cmd: count ($args[0]) must be numeric." if ($args[0] !~ /^\d?.?\d+$/);
		return "$name $cmd: action ($args[1]) must be numeric." if ($args[1] !~ /^\d?.?\d+$/);
		return "$name $cmd: action ($args[1]) must be 0 (previous state), 1 (stay on) or 2 (off)." if ($args[1] < 0) || ($args[1] > 2);
		
		my @params = split(/,/,$args[2]);
		my $pCnt = @params;
		return "$name $cmd: wrong count of parameter elements \"$pCnt\". Parameter must contain tuples of 4 elements (duration, mode, value, brightness)" if (($pCnt%4) != 0);
		my $i = 1;
		my $ret = "";
		
		foreach my $param (@params)
		{
			if (($i%4) == 1)
			{
				$ret.= "$name $cmd flow parameters: wrong parameter \"$param\" at $i. place. Duration must be numeric and equal or greater than 50.\n" if ($param !~ /^\d?.?\d+$/) || ($param < 50);
			}
			elsif (($i%4) == 2)
			{
				$ret.= "$name $cmd flow parameters: wrong parameter \"$param\" at $i. place. Choose mode from 1 (color), 2 (color temperature) or 7 (sleep).\n" if ($param != 1) && ($param != 2) && ($param != 7);
			}
			elsif (($i%4) == 3)
			{
				$ret.= "$name $cmd flow parameters: wrong parameter \"$param\" at $i. place. Value for rgb must be numeric and between 1 and 16777215.\n" if ($params[$i - 2] == 1) && (($param !~ /^\d?.?\d+$/) || ($param < 1) || ($param > 16777215));
				$ret.= "$name $cmd flow parameters: wrong parameter \"$param\" at $i. place. Value for color temperature must be numeric and between 1 and 16777215.\n" if ($params[$i - 2] == 2) && (($param !~ /^\d?.?\d+$/) || ($param < 1700) || ($param > 6500));
			}
			elsif (($i%4) == 0)
			{
				$ret.= "$name $cmd flow parameters: wrong parameter \"$param\" at $i. place. Brightness must be numeric and between 1 and 100.\n" if ($params[$i - 3] != 7) && (($param < 1) || ($param > 100));
			}
			
			$i++;
		}
		
		return "input parameter: $args[2]\n$ret" if ($ret ne "");
		
		my $action = $args[1] + 0;
		$action = 2 if ($action == 0) && ($hash->{READINGS}{power}{VAL} eq "off");		# override "previous state" with "off" if bulb state is off
		
		my $sCmd;
		$sCmd->{'method'}		= "start_cf";							# method:start_cf
		$sCmd->{'params'}->[0]	= $args[0] + 0;							# count
		$sCmd->{'params'}->[1]	= $action;								# action
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
	
	elsif (lc $cmd eq "raw")											# Answer won't be deleted in AnsQue
	{
		return "$name: Raw command can't be empty." if (!defined($args[0]));
		DevIo_OpenDev($hash, 0,, sub(){
			my ($hash, $err) = @_;
			Log3 $name, 2, "$name: $err" if($err);
			return "$err" if($err);		
		}) if ($hash->{STATE} ne "opened");
		return "$name: Can't send command, if bulb is not connected." if ($hash->{STATE} ne "opened");
		my $arg = join("",@args);
		Log3 $name, 2, "$name: sending raw command to bulb: $arg";
		Add_SendQue($hash,$arg,"raw");
		DevIo_SimpleWrite($hash, qq($arg\r\n), 2);
	}
	
	elsif (lc $cmd eq "flush")
	{
		Log3 $name, 2, "$name: user initiated flush of queues";
		YeeLight_Flush($hash);
	}
	
	elsif (lc $cmd eq "blink")
	{
		return "usage: set $name $cmd [count] [mode] [color] [time]" if ($cnt != 0) && ($cnt != 1) && ($cnt != 4);
		return "count must be numeric and at least 1" if ($cnt > 0) && (($args[0] < 1) || ($args[0] !~ /^\d?.?\d+$/));
		return "choose color_mode from 1 (RGB) or 2 (color temperatur)" if ($cnt > 1) && (($args[1] < 1) || ($args[1] > 2));
		return "color in RGB must be numeric, noted in hex and between 000001 - FFFFFF" if ($cnt > 1) && ($args[1] == 1) && (($args[2] !~ /^[0-9A-Fa-f]{6}$/) || ($args[2] eq "000000"));
		return "color temperature must be numeric and between 1700 - 6500" if ($cnt > 1) && ($args[1] == 2) && (($args[2] !~ /^\d?.?\d+$/) || ($args[2] < 1700) || ($args[2] > 6500));
		return "time must be numeric and at least 100" if ($cnt == 4) && (($args[3] !~ /^\d?.?\d+$/) || ($args[3] < 100));
		
		my $count	= $args[0]	if ($args[0]);
		my $mode	= $args[1]	if ($args[1]);
		my $color;
		$color		= $args[2]	if ($args[2]) && ($args[1] == 2);
		$color		= hex($args[2]) if ($args[2]) && ($args[1] == 1);
		my $time	= int($args[3] / 2) if ($args[3]);
		my $curMode = $hash->{READINGS}{color_mode}{VAL};
		my $curPower= $hash->{READINGS}{power}{VAL};
		my $curRGBorCT;
		
		if ($curMode eq "RGB")
		{
			$curMode	= 1;
			$curRGBorCT	= hex($hash->{READINGS}{rgb}{VAL});
			
		}
		elsif ($curMode eq "color temperature")
		{
			$curMode	= 2;
			$curRGBorCT	= $hash->{READINGS}{ct}{VAL};
		}
		elsif ($curMode eq "HSV")
		{
			$curMode	= 1;
			my $hue		= $hash->{READINGS}{hue}{VAL} + 0;
			my $sat		= $hash->{READINGS}{sat}{VAL} + 0;
			my $val		= 100;
			$curRGBorCT = HSVtoRGB($hue,$sat,$val);
			Log3 $name, 5, "$name: convertet HSV ($hue $sat 100) to RGB ($curRGBorCT)";
		}
		
		my $sCmd;
		$sCmd->{'method'}		= "start_cf";							# method:start_cf
		$sCmd->{'params'}->[0]	= 6 if ($cnt == 0);						# 6 visible changes (3 blink)
		$sCmd->{'params'}->[0]	= 2 * $count if ($count);				# 2 * $count visible changes ($count blink)
		$sCmd->{'params'}->[1]	= 0 if ($curPower eq "on");
		$sCmd->{'params'}->[1]	= 2 if ($curPower eq "off");
		
		my $flow = "500,".$curMode.",".$curRGBorCT.",";
		$flow = $time.",".$mode.",".$color."," if ($mode);
		
		$sCmd->{'params'}->[2]	= $flow."100,".$flow."1" if ($curPower eq "on");
		$sCmd->{'params'}->[2]	= $flow."1,".$flow."100" if ($curPower eq "off");
		
		YeeLight_SendCmd($hash,$sCmd,$cmd);
	}

	else
	{
		return SetExtensions($hash, $list, $name, $cmd, @args);
	}
	
	return undef;
}

sub
YeeLight_SendCmd
{
	my ($hash,$sCmd,$cmd,$rCnt) = @_;
	my $name		= $hash->{NAME};
	my $error		= undef;
	my $bHash		= $modules{YeeLightBridge}{defptr};
	my $bName		= $bHash->{NAME};
	my $defaultRamp = 0;
	$defaultRamp	= $attr{$bName}{defaultramp} if ($attr{$bName}{defaultramp});
	$defaultRamp	= $attr{$name}{defaultramp} if ($attr{$name}{defaultramp});
	
	if (lc $cmd eq "name"
		|| lc $cmd eq "default"
		|| lc $cmd eq "start_cf"
		|| lc $cmd eq "stop_cf"
		|| lc $cmd eq "dimdown"
		|| lc $cmd eq "dimup"
		|| lc $cmd eq "blink")
	{}
	elsif (defined($sCmd->{'params'}->[$rCnt]))
	{
		$error = "usage: set $name $cmd [milliseconds]" if ($sCmd->{'params'}->[$rCnt] !~ /^\d?.?\d+$/);
		$error = "minimum for milliseconds is 30 or 0 for sudden" if ($sCmd->{'params'}->[$rCnt] < 30) && ($sCmd->{'params'}->[$rCnt] != 0);
		Log3 $name, 4, "$name: $error" if defined($error);
		return $error if defined($error);
		$sCmd->{'params'}->[$rCnt - 1] = "smooth";						# flow
		$sCmd->{'params'}->[$rCnt] += 0;								# force ramp time to be int
	}
	elsif ($defaultRamp != 0)
	{
		$sCmd->{'params'}->[$rCnt - 1] = "smooth";						# flow
		$sCmd->{'params'}->[$rCnt] = $defaultRamp + 0;					# force default ramp time to be int
	}
	elsif ($sCmd->{'method'} eq "set_ct_abx")
	{

		$sCmd->{'params'}->[$rCnt - 1] = "sudden";						# no flow
		$sCmd->{'params'}->[$rCnt] = 0;									# no flow
	}
	
	YeeLight_IsOn($hash) if (lc $cmd ne "statusrequest") && (lc $cmd ne "on") && (lc $cmd ne "off") && (lc $cmd ne "toggle") && (lc $cmd ne "name");
	
	$sCmd->{'id'}	= YeeLight_Bridge_GetID($hash);
	my $send		= encode_json($sCmd);
	
	DevIo_OpenDev($hash, 0,, sub(){
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
		return "$err" if($err);		
	}) if ($hash->{STATE} ne "opened");
	return "$name: Can't send command, if bulb is not connected." if ($hash->{STATE} ne "opened");
	Add_SendQue($hash,$send,$sCmd->{'id'});
	DevIo_SimpleWrite($hash, qq($send\r\n), 2);
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
	
	DevIo_OpenDev($hash, 0,, sub(){ 
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
		return "$err" if($err);
	}) if ($hash->{STATE} ne "opened");
	return "$name: Can't do status request, if bulb is not connected." if ($hash->{STATE} ne "opened");
	Add_SendQue($hash,$send,$msgID);
	DevIo_SimpleWrite($hash, qq($send\r\n), 2);
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
	
	$buf =~ s/\r\n||\n//g;
	
	Log3 $name, 5, "$name: Reading raw: $buf";
	
	my $read;
	my $search = "}{";
	my $offset = 0;
	my $result = index($buf, $search, $offset);
	
	if ($result == -1)
	{
		Log3 $name, 4, "reading from $name: $buf";
		Add_AnsQue($hash,$buf);
	}
	else
	{
		while ($result != -1)
		{
			$read = substr($buf,$offset,($result - $offset + 1));
			Log3 $name, 4, "reading from $name: $read";
		
			Add_AnsQue($hash,$read);
			$offset = index($buf, "{", $result);
			$result = index($buf, $search, $offset);
		}
		
		$read = substr($buf,$offset,length($buf));
		Log3 $name, 4, "reading from $name: $read";
		
		Add_AnsQue($hash,$read);
	}
	
	return undef;
}

sub
Add_SendQue
{
	my ($hash,$send,$id) = @_;
	my $name = $hash->{NAME};
	
	if ($id eq "raw")
	{
		my $json;
		eval { $json = decode_json($send); };
		if ($@)
		{
			my $ret = $id.': '.$send;
			Log3 $name, 1, "$name ErrorQueue: added send command $ret (not a valid json string). Error: $@";
			push(@{$hash->{helper}->{ErrQue}},"not valid json: ".$ret);
		}
		else
		{
			$id = $json->{'id'} if (defined($json->{'id'}));
			$hash->{helper}->{SendQue}->{$id} = $send;
			Log3 $name, 5, "$name SendQueue: added $hash->{helper}->{SendQue}->{$id} with id:$id";
		}
	}
	else
	{
		$hash->{helper}->{SendQue}->{$id} = $send;
		Log3 $name, 5, "$name SendQueue: added $hash->{helper}->{SendQue}->{$id} with id:$id";
	}
	
	my $bHash = $modules{YeeLightBridge}{defptr};
	my $bName = $bHash->{NAME};
	my $timeout	= 3;
	$timeout	= $attr{$bName}{timeout} if $attr{$bName}{timeout};
	$timeout	= $attr{$name}{timeout} if $attr{$name}{timeout};
	if ($timeout != 0)
	{
		RemoveInternalTimer($hash,"YeeLight_IsReachable");
		InternalTimer(gettimeofday() + $timeout,"YeeLight_IsReachable",$hash);
	}
	
	return undef;
}

sub
Add_AnsQue
{
	my ($hash,$ans) = @_;
	my $name = $hash->{NAME};
	
	my $json;
	eval { $json = decode_json($ans); };
	if ($@ && $ans !~ /error/)
	{
		my $ret = RepairJson($hash,$ans);
		Log3 $name, 1, "$name ErrorQueue: added answer \"$ans\" (not a valid json string). Error: $@";
		push(@{$hash->{helper}->{ErrQue}},"not valid json: ".$ans);
	}
	else
	{
		push(@{$hash->{helper}->{AnsQue}},$ans);
		my $length = @{$hash->{helper}->{AnsQue}};
		Log3 $name, 5, "$name AnswerQueue: added $hash->{helper}->{AnsQue}[($length - 1)]";
		
		Do_AnsQue($hash);
	}
	
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
		if ($ans =~ /\"id\"\:\(null\)/)
		{
			Log3 $name, 1, "$name ErrorQueue: received answer with unknown id ($ans)";
			push(@{$hash->{helper}->{ErrQue}},"unknown id: ".$ans);
			Log3 $name, 5, "$name AnswerQueue: deleted $ans";
			splice(@{$hash->{helper}->{AnsQue}}, $i, 1);
		}
		else
		{
			my $jsonAns = decode_json($ans);
			if (defined($jsonAns->{'method'}) && $jsonAns->{'method'} eq "props")
			{
				Log3 $name, 4, "$name: detected notification broadcast ($ans)";
				YeeLight_Parse($hash,$jsonAns);
				Log3 $name, 5, "$name AnswerQueue: deleted $ans";
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
						Log3 $name, 5, "$name SendQueue: deleted $send";
						delete $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
					}
					elsif ($ans =~ /error/)
					{
						Log3 $name, 1, "$name error sending $jsonSend->{'id'}: $send";
						Log3 $name, 5, "$name SendQueue deleted $send";
						delete $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
					}
					elsif (defined($jsonAns->{'result'}) && defined($jsonAns->{'result'}->[11]))
					{
						YeeLight_ParseStatusRequest($hash,$jsonAns);
						Log3 $name, 5, "$name SendQueue: deleted $send";
						delete $hash->{helper}->{SendQue}->{$jsonAns->{'id'}};
					}
					else
					{
						Log3 $name, 1, "$name SendQueue: couldn't match answer ($ans)";
					}
					
					Log3 $name, 5, "$name AnswerQueue: deleted $ans";
					splice(@{$hash->{helper}->{AnsQue}}, $i, 1);
				}
			}
			
			$i++;
		}
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
	my $hexrgb	= sprintf("%06x",$rgb);
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
			return "Invalid parameter for $attrName. $attrName must be numeric and at least 30." if ($attrVal !~ /^\d?.?\d+$/) || ($attrVal < 30);
		}
		elsif ($attrName eq "updateIP")
		{
			return "Invalid parameter for $attrName. Choose \"0\" (don't update IP) or \"1\" (update IP)." if ($attrVal != 0) && ($attrVal != 1);
		}
		elsif ($attrName eq "timeout")
		{
			return "Invalid parameter for $attrName. $attrName must be numeric." if ($attrVal !~ /^\d?.?\d+$/);
		}
		elsif ($attrName eq "keepAlive")
		{
			return "Invalid parameter for $attrName. $attrName must be numeric and at least 60 or 0." if ($attrVal !~ /^\d?.?\d+$/) || (($attrVal < 60) && ($attrVal == 0));
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
YeeLight_Flush
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	my $ret = "";
	my $answer = "";
	my $send = "";
	my $error = "";

	my $ans;
	while(@{$hash->{helper}->{AnsQue}} != 0)
	{
		$ans	 = shift(@{$hash->{helper}->{AnsQue}});
		$answer .= "   $ans\n";
	}
	
	$answer .= "AnswerQueue:\n".$answer if ($answer ne "");
	
	foreach my $s(sort keys %{$hash->{helper}->{SendQue}})
	{
		$send .= $hash->{helper}->{SendQue}->{$s}."\n";
		delete $hash->{helper}->{SendQue}->{$s};
	}
	
	$send .= "SendQueue:\n".$send if ($send ne "");
	
	my $err;
	while (@{$hash->{helper}->{ErrQue}} != 0)
	{
		$err	= shift(@{$hash->{helper}->{ErrQue}});
		$error .= "   $err\n";
	}
	
	$error .= "ErrorQueue:\n".$error if ($error ne "");
	
	$ret .= $send if ($send ne "");
	$ret .= $answer if ($answer ne "");
	$ret .= $error if ($error ne "");
		
	if ($ret ne "")
	{
		$ret = "$name: doing flush:\n".$ret;
	}
	else
	{
		$ret .= "$name: Tried to empty queues, but all three were empty.";
	}
	
	Log3 $name, 4, "$ret";
}

sub
YeeLight_IsOn
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	YeeLight_SelectSetCmd($hash,"on") if ($hash->{READINGS}{power}{VAL} eq "off");
	return undef;
}

sub
YeeLight_Ready
{
	my ($hash) = @_;
 
	# Versuch eines Verbindungsaufbaus, sofern die Verbindung beendet ist.
	return DevIo_OpenDev($hash, 1, undef ) if ( $hash->{STATE} eq "disconnected" );
}

sub
YeeLight_IsReachable
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	if (%{$hash->{helper}->{SendQue}} != 0)
	{
		foreach my $s (keys %{$hash->{helper}->{SendQue}})
		{
			my $send = $hash->{helper}->{SendQue}->{$s};
			Log3 $name, 1, "$name ErrorQueue: command wasn't answered in time ($send)";
			push(@{$hash->{helper}->{ErrQue}},"not in time: ".$send);
			Log3 $name, 5, "$name SendQueue: deleted $send";
			delete $hash->{helper}->{SendQue}->{$s};
		}
		DevIo_Disconnected($hash);
	}
	
	return undef;	
}

# subroutines for bridge communication

sub
YeeLightBridge_Parse
{
	my ($io_hash,$incData) = @_;
	my $name = $io_hash->{NAME};
	
	Log3 $name, 5, "$name (YeeLightBridge): $incData";
	
	my $sHash;
	if ($incData =~ /NOTIFY/)
	{
		foreach my $data (split(/\r\n/,$incData))
		{
			my @d = split(/: /,$data);
			$sHash->{$d[0]} = $d[1];
		}
		
		my $bHash = $modules{YeeLightBridge}{defptr};
		my $bName = $bHash->{NAME};
		my $updateIP = 1;
		$updateIP = $attr{$bName}{updateIP} if ($attr{$bName}{updateIP});
		$updateIP = $attr{$name}{updateIP} if ($attr{$name}{updateIP});
		
		
		my $host = $sHash->{"Location"};
		$host = substr($host,11,length($host)-11);
		$host = substr($host,0,length($host)-6);
		
		my $hash;
		if ($modules{YeeLight}{defptr}{$sHash->{"id"}})
		{
			$hash = $modules{YeeLight}{defptr}{$sHash->{"id"}};
			YeeLightBridge_UpdateDev($hash,$sHash,$updateIP);
			
			return $hash->{NAME};
		}
		elsif ($modules{YeeLight}{defptr}{$host})
		{
			$hash = $modules{YeeLight}{defptr}{$host};
			if ($updateIP == 1)		# update IP true
			{
				$modules{YeeLight}{defptr}{$sHash->{"id"}} = $hash;
				delete($modules{YeeLight}{defptr}{$host});
			}
			YeeLightBridge_UpdateDev($hash,$sHash,$updateIP);
			
			return $hash->{NAME};
		}
		else
		{
			foreach my $y (%{$modules{YeeLight}{defptr}})
			{
				$hash = $modules{YeeLight}{defptr}{$y};
				if ($hash->{IP} eq $host)
				{
					if ($updateIP == 1)		# update IP true
					{
						$modules{YeeLight}{defptr}{$sHash->{"id"}} = $hash;
						delete($modules{YeeLight}{defptr}{$host});
					}
					YeeLightBridge_UpdateDev($hash,$sHash,$updateIP);
				
					return $hash->{NAME};
				}
			}
		}

		my $newName = "YeeLight_".$sHash->{"id"};
		$newName	= "YeeLight_".$sHash->{"name"} if ($sHash->{"name"});
		
		return "UNDEFINED ".$newName." YeeLight ".$host." ".$sHash->{"id"};
	}	
}

sub
YeeLightBridge_UpdateDev
{
	my ($hash,$mcHash,$updateIP) = @_;
	my $name = $hash->{NAME};
	
	my $DeviceName	= $mcHash->{"Location"};
	$DeviceName		= substr($DeviceName,11,length($DeviceName)-11);
	my $host		= substr($DeviceName,0,length($DeviceName)-6);
	my $port		= substr($DeviceName,length($host) + 1);
	my $id			= $mcHash->{"id"};
	my $model		= $mcHash->{"model"};
	my $fw_ver		= $mcHash->{"fw_ver"};
	my $support		= $mcHash->{"support"};
	my $power		= $mcHash->{"power"};
	my $bright		= $mcHash->{"bright"};
	my $color_mode	= $mcHash->{"color_mode"};
	$color_mode		= "RGB"					if ($color_mode eq 1);
	$color_mode		= "color temperature"	if ($color_mode eq 2);
	$color_mode		= "HSV" 				if ($color_mode eq 3);
	my $ct			= $mcHash->{"ct"};
	my $rgb			= $mcHash->{"rgb"};
	my $hexrgb		= sprintf("%06x",$rgb);
	my $b			= $rgb % 256;
	my $g			= (($rgb - $b) / 256) % 256;
	my $r			= ($rgb - $b - ($g * 256)) / (256 * 256);
	my $hue			= $mcHash->{"hue"};
	my $sat			= $mcHash->{"sat"};
	my $bulbName	= $mcHash->{"name"};
	
	if ($updateIP == 1)	# update IP true
	{
		$hash->{HOST}				= $host				if !($hash->{HOST}) || ($hash->{HOST} ne $host);
		$hash->{DeviceName}			= $DeviceName		if !($hash->{DeviceName}) || ($hash->{DeviceName} ne $DeviceName);
		$hash->{ID}					= $id				if !($hash->{ID}) || ($hash->{ID} ne $id);
	}
	$hash->{PORT}				= $port				if !($hash->{PORT}) || ($hash->{PORT} ne $port);
	$hash->{MODEL}				= $model			if !($hash->{MODEL}) || ($hash->{MODEL} ne $model);
	$hash->{FW_VER}				= $fw_ver			if !($hash->{FW_VER}) || ($hash->{FW_VER} ne $fw_ver);
	$hash->{helper}->{support}	= $support			if !($hash->{helper}->{support}) || ($hash->{helper}->{support} ne $support);
	
	readingsBeginUpdate($hash);
		readingsBulkUpdateIfChanged($hash,"power",$power);
		readingsBulkUpdateIfChanged($hash,"bright",$bright);
		readingsBulkUpdateIfChanged($hash,"ct",$ct);
		readingsBulkUpdateIfChanged($hash,"rgb",$hexrgb);
		readingsBulkUpdateIfChanged($hash,"rgb_blue",$b);
		readingsBulkUpdateIfChanged($hash,"rgb_green",$g);
		readingsBulkUpdateIfChanged($hash,"rgb_red",$r);
		readingsBulkUpdateIfChanged($hash,"hue",$hue);
		readingsBulkUpdateIfChanged($hash,"sat",$sat);
		readingsBulkUpdateIfChanged($hash,"color_mode",$color_mode);
		readingsBulkUpdateIfChanged($hash,"name",$bulbName);
	readingsEndUpdate($hash,1);
	
	return undef;
}

# helper subroutines

sub
IsValidIP
{
	return $_[0] =~ /^[\d\.]*$/ && inet_aton($_[0]);
}

sub
RepairJson
{
	my ($hash,$json) = @_;
	my $name = $hash->{NAME};
	my $length = length($json);
	my $oldJson = $json;
	
	$json .= "}" if (($length - 1) != rindex($json,"}"));
	$json = "{".$json if (index($json,"{") != 0);
	
	if ($json eq $oldJson && ($length - 2) != rindex($json,"}}")) 
	{
		$json .= "}";
	}
	
	if ($json ne $oldJson)
	{
		Log3 $name, 1, "$name: Invalid json $oldJson repaired to $json";
		my $ret;
		eval { $ret = encode_json($json); };
		if ($@)
		{
			Log3 $name, 1, "$name ErrorQueue: added repaired answer \"$json\" (not a valid json string). Error: $@";
			push(@{$hash->{helper}->{ErrQue}},$json);
		}
		else
		{
			push(@{$hash->{helper}->{AnsQue}},$json);
			my $length = @{$hash->{helper}->{AnsQue}};
			Log3 $name, 1, "$name AnswerQueue: added $hash->{helper}->{AnsQue}[($length - 1)] after repair";
			
			Do_AnsQue($hash);
		}
	}	
}

sub
HSVtoRGB
{
	my ($hue, $sat, $val) = @_;

	if ($sat == 0) 
	{
		return int(($val * 2.55) +0.5), int(($val * 2.55) +0.5), int(($val * 2.55) +0.5);
	}
	$hue %= 360;
	$hue /= 60;
	$sat /= 100;
	$val /= 100;
	
	my $i = int($hue);

	my $f = $hue - $i;
	my $p = $val * (1 - $sat);
	my $q = $val * (1 - $sat * $f);
	my $t = $val * (1 - $sat * (1 - $f));
	
	my ($r, $g, $b);
	
	if ( $i == 0 )
	{
		($r, $g, $b) = ($val, $t, $p);
	}
	elsif ( $i == 1 )
	{
		($r, $g, $b) = ($q, $val, $p);
	}
	elsif ( $i == 2 ) 
	{
		($r, $g, $b) = ($p, $val, $t);
	}
	elsif ( $i == 3 ) 
	{
		($r, $g, $b) = ($p, $q, $val);
	}
	elsif ( $i == 4 )
	{
		($r, $g, $b) = ($t, $p, $val);
	}
	else
	{
		($r, $g, $b) = ($val, $p, $q);
	}
	$r = int(($r * 255) + 0.5);
	$g = int(($g * 255) + 0.5);
	$b = int(($b * 255) + 0.5);
	my $rgb = ($r * 256 * 256) + ($g * 256) + $b;
	
	return $rgb;
}

1;