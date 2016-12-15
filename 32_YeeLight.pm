##############################################
# $Id: 32_YeeLight.pm 2016-26-14 thaliondrambor $

# TODO
# listening TCP-socket for change of status -> remove periodic status update
# light functions: dimup, dimdown, toogle, color temperature, timer,
#				   schedules, color flow
# scenes
# software bridge (UDP): autocreate devices (ID), search for devices,
#						 listening for changes (eg. IP)

# versions
# 00 start

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

	$hash->{DefFn}        = "YeeLight_Define";
	$hash->{UndefFn}      = "YeeLight_Undef";
	$hash->{ShutdownFn}   = "YeeLight_Undef";
	$hash->{SetFn}        = "YeeLight_Set";
	$hash->{AttrList}     = ""
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
	$data{YeeLightBridge}{msgID}++;
	readingsSingleUpdate($hash,"msgID",$curID,1);
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
	$list .= "hsv ";
	$list .= "rgb ";
	$list .= "brightness ";
	$list .= "color ";
	$list .= "statusrequest:noArg ";

	if (lc $cmd eq 'on'
		|| lc $cmd eq 'off'
		|| lc $cmd eq 'hsv'
		|| lc $cmd eq 'rgb'
		|| lc $cmd eq 'brightness'
		|| lc $cmd eq 'color'
		|| lc $cmd eq 'statusrequest')
	{
	    Log3 $name, 3, "YeeLight $name - set $name $cmd ".join(" ", @val);
		
		return YeeLight_SelectSetCmd($hash, $cmd, @val) if (@val ) || (lc $cmd eq 'statusrequest') || (lc $cmd eq "on") || (lc $cmd eq "off");
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
	my $cmdSet = $hash->{helper}->{COMMANDSET}; 
	return "unknown command ($cmd): choose one of ".join(", ", $cmdSet) if ($cmd eq "?"); 


	if (lc $cmd eq 'on' || $cmd eq 'off')
	{
		my $params	= '["'.$cmd.'"';
		my $method	= '"set_power"';
		my $ret 	= YeeLight_SendCmd($hash,$method,$params,$cmd,$args[0]);
		
		if ($ret eq "ok")
		{
			readingsBeginUpdate($hash);
			readingsBulkUpdateIfChanged($hash,"power",$cmd);
			readingsEndUpdate($hash,1);
		}
		else
		{
			return $ret if (defined $ret);
			return "Unknown error.";
		}
	}
	
	elsif (lc $cmd eq "hsv")
	{
		return "usage: set $name $cmd [hue] [saturation]" if !(($cnt == 2) || ($cnt == 3)) || ($args[0] !~ /^\d?.?\d+$/) || ($args[1] !~ /^\d?.?\d+$/);
		return "choose hue between 0 and 359" if ($args[0] < 0) || ($args[0] > 359);
		return "choose saturation between 0 and 100" if ($args[1] < 0) || ($args[1] > 100);
		my $hue			= int($args[0]);
		my $saturation	= int($args[1]);
		my $method	= '"set_hsv"';
		my $params	= '['.$hue.','.$saturation;
		my $ret		= YeeLight_SendCmd($hash,$method,$params,$cmd,$args[2]);
		
		if ($ret eq "ok")
		{
			readingsBeginUpdate($hash);
			readingsBulkUpdateIfChanged($hash,"hue",$hue);
			readingsBulkUpdateIfChanged($hash,"saturation",$saturation);
			readingsEndUpdate($hash,1);
		}
		else
		{
			return $ret if (defined $ret);
			return "Unknown error.";
		}		
	}
	
	elsif (lc $cmd eq "statusrequest")
	{
		YeeLight_StatusRequest($hash);
	}
	
	elsif (lc $cmd eq "rgb")
	{
		return "usage: set $name $cmd [red] [green] [blue]" if !(($cnt == 3) || ($cnt == 4)) || ($args[0] !~ /^\d?.?\d+$/) || ($args[1] !~ /^\d?.?\d+$/) || ($args[2] !~ /^\d?.?\d+$/);
		return "choose color (red, green, blue) between 0 and 255" if ($args[0] < 0) || ($args[0] > 255) || ($args[1] < 0) || ($args[1] > 255) || ($args[2] < 0) || ($args[2] > 255);
		my $r	= int($args[0]);
		my $g	= int($args[1]);
		my $b	= int($args[2]);
		my $rgb	= ($r * 256 * 256) + ($g * 256) + $b;
		$rgb	= (255 * 256 * 256) + (255 * 256) + 255 if ($rgb == 0);
		
		my $method	= '"set_rgb"';
		my $params	= '['.$rgb;
		my $ret		= YeeLight_SendCmd($hash,$method,$params,$cmd,$args[3]);
		
		if ($ret eq "ok")
		{
			readingsBeginUpdate($hash);
			readingsBulkUpdateIfChanged($hash,"RGB_Red",$r);
			readingsBulkUpdateIfChanged($hash,"RGB_Green",$g);
			readingsBulkUpdateIfChanged($hash,"RGB_Blue",$b);
			readingsEndUpdate($hash,1);
		}
		else
		{
			return $ret if (defined $ret);
			return "Unknown error.";
		}
	}

	elsif (lc $cmd eq "brightness")
	{
		return "usage: set $name $cmd [brightness]" if !(($cnt == 1) || ($cnt == 2)) || ($args[0] !~ /^\d?.?\d+$/);
		return "choose brightness between 1 and 100" if ($args[0] < 1) || ($args[0] > 100);
		my $bright	= int($args[0]);
		my $method	= '"set_bright"';
		my $params	= '['.$bright;
		my $ret		= YeeLight_SendCmd($hash,$method,$params,$cmd,$args[1]);
		
		if ($ret eq "ok")
		{
			readingsBeginUpdate($hash);
			readingsBulkUpdateIfChanged($hash,"brightness",$bright);
			readingsEndUpdate($hash,1);
		}
		else
		{
			return $ret if (defined $ret);
			return "Unknown error.";
		}
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
		
		my $method	= '"set_rgb"';

		if (!$color{lc($args[0])})
		{
			my @colorKeys	= keys(%color);
			my $keys		= join(', ',@colorKeys);
			return "Unknown color. Choose from: $keys";
		}
		my @rgb = split(/\,/,$color{lc($args[0])});
		my $setColor = ($rgb[0] * 256 *256) + ($rgb[1] * 256) + $rgb[2];
		my $params	= '['.$setColor;
		
		my $ret = YeeLight_SendCmd($hash,$method,$params,$cmd,$args[1]);
		
		if ($ret eq "ok")
		{
			my @rgb = split(/\,/,$color{lc($args[0])});
			readingsBeginUpdate($hash);
			readingsBulkUpdateIfChanged($hash,"RGB_Red",$rgb[0]);
			readingsBulkUpdateIfChanged($hash,"RGB_Green",$rgb[1]);
			readingsBulkUpdateIfChanged($hash,"RGB_Blue",$rgb[2]);
			readingsEndUpdate($hash,1);
		}
		else
		{
			return $ret if (defined $ret);
			return "Unknown error.";
		}
	}
	
	# TODO
	#elsif ($cmd eq 'dimup')
	#{
	#}
	
	#elsif ($cmd eq 'dimdown')
	#{
	#}
	
	#toogle
	#color temperature
	#timer
	#schedules
	#color flow
}

sub
YeeLight_SendCmd
{
	my ($hash,$method,$params,$cmd,$arg) = @_;
	my $name = $hash->{NAME};
	my $effect	= "sudden";
	my $ramp	= 0;
	my $error = undef;
	($ramp,$effect,$error) = YeeLight_Ramp($hash,$cmd,$arg) if (defined $arg);
	return $error if (defined $error);
	
	$params	.= ',"'.$effect.'",'.$ramp.']';
	my $msgID	= YeeLight_Bridge_GetID($hash);
	my $send	= qq({"id":$msgID, "method":$method, "params":$params}\r\n);
		
	DevIo_OpenDev($hash, 0,, sub(){ 
		my ($hash, $err) = @_;
		Log3 $name, 2, "$name: $err" if($err);
	});
	my $ret		= DevIo_Expect($hash, $send, 2);
	Log3 $name, 4, "$name: $send returns $ret";
	return "$name: Error: $ret" if ($ret =~ /error/) || (!$ret);
	my $answer	= decode_json($ret);
	
	return "ok" if ($answer) && ($answer->{'id'} eq $msgID) && ($answer->{'result'}->[0] eq "ok");
	return undef;
}

sub
YeeLight_Ramp
{
	my ($hash,$cmd,$arg) = @_;
	my $name = $hash->{NAME};
	my $error = undef;
	if ($arg !~ /^\d?.?\d+$/)	{$error = "usage: set $name $cmd [milliseconds]";}
	elsif ($arg < 30)			{$error = "minimum for milliseconds is 30";}
	Log3 $name, 4, "$name: $error";
	my $ramp = $arg;
	my $effect = "smooth";
	return ($ramp, $effect, $error);
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
		readingsBulkUpdateIfChanged($hash,"colortemperatur",$answer->{'result'}->[2]);
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