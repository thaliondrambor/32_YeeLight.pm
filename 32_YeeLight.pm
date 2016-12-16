##############################################
# $Id: 32_YeeLight.pm 2016-26-14 thaliondrambor $

# TODO
# listening TCP-socket for change of status -> remove periodic status update
# light functions: timer, schedules, color flow
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

	$hash->{DefFn}			= "YeeLight_Define";
	$hash->{UndefFn}		= "YeeLight_Undef";
	$hash->{ShutdownFn}		= "YeeLight_Shutdown";
	$hash->{SetFn}			= "YeeLight_Set";
	$hash->{AttrFn}			= "YeeLight_Attr";
	$hash->{AttrList}		= 
		"defaultramp"
		." $readingFnAttributes";

	return undef;
}

sub
YeeLight_Define
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def); 
	my $name = $a[0];
	
	return "wrong syntax: define <name> YeeLight <IP> [INTERVAL]"				if !((@a == 2) || (@a == 3));
	return "wrong input for IP-address: 'xxx.xxx.xxx.xxx' (0 <= xxx <= 255)"	if (!IsValidIP($a[2]));
	return "wrong input for interval: minimum is 900"							if ($a[3]) && (($a[3] !~ /^\d?.?\d+$/) || ($a[3] < 900));
	
	DevIo_CloseDev($hash);
	
	$hash->{HOST}		= $a[2] if ($a[2]);
    $hash->{PORT}		= 55443;
    $hash->{PROTO}		= 1;
	$hash->{NOTIFYDEV}	= "global";
	$hash->{INTERVAL}	= $a[3]?$a[3]:1800;
	
	Log3 $name, 3, "YeeLight $name defined at $hash->{HOST}:$hash->{PORT}";
	
	$attr{$name}{room} = "YeeLight" if(!defined( $attr{$name}{room}));
        
	my $dev = $hash->{HOST}.':'.$hash->{PORT};
	$hash->{DeviceName} = $dev;
	
	YeeLight_GetUpdate($hash);
	
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
	#readingsSingleUpdate($hash,"msgID",$curID,1);
	return $curID;
}

sub
YeeLight_Notify
{
	my ($own_hash,$dev_hash) = @_;
	my $own_name = $own_hash->{NAME};
	return undef if (IsDisabled($own_name));
	
	my $devName = $dev_hash->{NAME};
	my $events = deviceEvents($dev_hash,1);
	return undef if(!$events);
 
	foreach my $event (@{$events})
	{
		InternalTimer(gettimeofday() + 1, "YeeLight_GetUpdate", $own_hash) if ($devName eq "global") && ($event eq "INITIALIZED");
	}
}

sub
YeeLight_GetUpdate
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	Log3 $name, 4, "$name: GetUpdate";
	YeeLight_StatusRequest($hash);
	
	InternalTimer(gettimeofday() + $hash->{INTERVAL}, "YeeLight_GetUpdate", $hash);	
	
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
	$list .= "brightness ";
	$list .= "dimup ";
	$list .= "dimdown ";
	$list .= "color ";
	$list .= "ct ";
	$list .= "statusrequest:noArg ";

	if (lc $cmd eq 'on'
		|| lc $cmd eq 'off'
		|| lc $cmd eq 'toggle'
		|| lc $cmd eq 'hsv'
		|| lc $cmd eq 'hue'
		|| lc $cmd eq 'sat'
		|| lc $cmd eq 'rgb'
		|| lc $cmd eq 'brightness'
		|| lc $cmd eq 'dimup'
		|| lc $cmd eq 'dimdown'
		|| lc $cmd eq 'color'
		|| lc $cmd eq 'ct'
		|| lc $cmd eq 'statusrequest')
	{
	    Log3 $name, 3, "YeeLight $name - set $name $cmd ".join(" ", @val);
		
		return YeeLight_SelectSetCmd($hash, $cmd, @val) if (@val ) || (lc $cmd eq 'statusrequest') || (lc $cmd eq "on") || (lc $cmd eq "off") || (lc $cmd eq "dimup") || (lc $cmd eq "dimdown") || (lc $cmd eq "toggle");
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
		
		YeeLight_StatusRequest($hash);
		
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
		
		YeeLight_StatusRequest($hash);
		
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

	elsif (lc $cmd eq "brightness")
	{
		return "usage: set $name $cmd [brightness]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose brightness between 1 and 100" if ($args[0] < 1) || ($args[0] > 100);
		
		my $sCmd;
		$sCmd->{'method'}		= "set_bright";							# method:set_bright
		$sCmd->{'params'}->[0]	= int($args[0]);						# brightness
		$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);				# ramp time
		
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
			YeeLight_StatusRequest($hash);
		
			my $oldBright = $hash->{READINGS}{brightness}{VAL};
			$args[0] = $oldBright + $args[0] if ($cmd eq "dimup");
			$args[0] = $oldBright - $args[0] if ($cmd eq "dimdown");
			$args[0] = 1 if ($args[0] < 1);
			$args[0] = 100 if ($args[0] > 100);
		
			YeeLight_SelectSetCmd($hash,'brightness',@args);
		}
		else
		{
			return "usage: set $name $cmd [dimup/dimdown] <VALUE>";
		}
	}
	
	elsif ($cmd eq "ct")
	{
		return "usage: set $name $cmd [COLORTEMPERATUR]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose color temperature between 1700 and 6500" if ($args[0] < 1700) || ($args[0] > 6500);
		
		my $sCmd;
		$sCmd->{'method'}		= "set_ct_abx";							# method:set_ct_abx
		$sCmd->{'params'}->[0]	= int($args[0]);						# color temperature
		$sCmd->{'params'}->[2]	= $args[1] if ($args[1]);				# ramp time
		
		YeeLight_SendCmd($hash,$sCmd,$cmd,2);
	}
	
	elsif ($cmd eq "toggle")
	{
		YeeLight_StatusRequest($hash);
		my $power = $hash->{READINGS}{power}{VAL};
		YeeLight_SelectSetCmd($hash,"on",@args) if ($power eq "off");
		YeeLight_SelectSetCmd($hash,"off",@args) if ($power eq "on");
	}
	
	# TODO
	
	#timer
	#schedules
	#color flow
}

sub
YeeLight_SendCmd
{
	my ($hash,$sCmd,$cmd,$rCnt) = @_;
	my $name	= $hash->{NAME};
	my $error	= undef;
	
	if (defined($sCmd->{'params'}->[$rCnt]))
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
	
	$sCmd->{'id'}	= YeeLight_Bridge_GetID($hash);
	my $send		= encode_json($sCmd);
	$send			.= "\r\n";
	$send			= qq($send);
		
	DevIo_OpenDev($hash, 0,, sub(){ 
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
	});
	my $ret		= DevIo_Expect($hash, $send, 2);
	Log3 $name, 4, "$name: $send returns $ret";
	return "$name: Error: $ret" if ($ret =~ /error/) || (!$ret);
	my $answer	= decode_json($ret);
	
	if (($answer) && ($answer->{'id'} eq $sCmd->{'id'}) && ($answer->{'result'}->[0] eq "ok"))
	{
		YeeLight_StatusRequest($hash);
		return undef;
	}
	else
	{
		return "Unknown error.";
	}
}

sub
YeeLight_StatusRequest
{
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $msgID	= YeeLight_Bridge_GetID($hash);
	my $send	= qq({"id":$msgID,"method":"get_prop","params":["power","bright","ct","rgb","hue","sat","color_mode","flowing","delayoff","flow_params","music_on","name"]}\r\n);
	
	DevIo_OpenDev($hash, 0,, sub(){ 
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
	});
	my $ret		= DevIo_Expect($hash, $send, 2);
	Log3 $name, 4, "$name: $send returns $ret";
	return "$name: Error: $ret" if ($ret =~ /error/) || (!$ret);
	
	my $answer		= decode_json($ret);
	my $rgb			= $answer->{'result'}->[3];
	my $hexrgb		= sprintf("%X",$rgb);
	my $b			= $rgb % 256;
	my $g			= (($rgb - $b) / 256) % 256;
	my $r			= ($rgb - $b - ($g * 256)) / (256 * 256);
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
		readingsBulkUpdateIfChanged($hash,"power",$answer->{'result'}->[0]);
		readingsBulkUpdateIfChanged($hash,"brightness",$answer->{'result'}->[1]);
		readingsBulkUpdateIfChanged($hash,"colortemperature",$answer->{'result'}->[2]);
		readingsBulkUpdateIfChanged($hash,"RGB",$hexrgb);
		readingsBulkUpdateIfChanged($hash,"RGB_Blue",$b);
		readingsBulkUpdateIfChanged($hash,"RGB_Green",$g);
		readingsBulkUpdateIfChanged($hash,"RGB_Red",$r);
		readingsBulkUpdateIfChanged($hash,"hue",$answer->{'result'}->[4]);
		readingsBulkUpdateIfChanged($hash,"saturation",$answer->{'result'}->[5]);
		readingsBulkUpdateIfChanged($hash,"colormode",$colormode);
		readingsBulkUpdateIfChanged($hash,"Colorflow",$colorflow);
		readingsBulkUpdateIfChanged($hash,"SleepTimer",$answer->{'result'}->[8]);
		readingsBulkUpdateIfChanged($hash,"flowparams",$answer->{'result'}->[9]);
		readingsBulkUpdateIfChanged($hash,"musicmode",$musicmode);
		readingsBulkUpdateIfChanged($hash,"name",$answer->{'result'}->[11]);
		readingsEndUpdate($hash,1);
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
			return "Invalid parameter for $attrName. $attrName must be a number and more than 30." if ($attrVal !~ /^\d?.?\d+$/) && ($attrVal < 30);
		}
	}
	return undef;
}

sub
YeeLight_Init
{
	return undef;
}

# helper subroutines

sub
IsValidIP
{
	return $_[0] =~ /^[\d\.]*$/ && inet_aton($_[0]);
}

1;