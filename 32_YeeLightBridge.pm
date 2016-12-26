##############################################
# $Id: 32_YeeLightBridge.pm 2016-12-26 thaliondrambor $
#
# versions
# 00 start
# 01 added timeout, keepAlive
#
# verbose level
# 0: quit
# 1: error
# 2: warning
# 3: user command
# 4: 1st technical level (detailed internal reporting)
# 5: 2nd technical level (full internal reporting)

package main;

use strict;
use warnings;
use POSIX;
use IO::Socket::Multicast;
use IO::Socket::INET;

#----------------------------Constants------------------------------------------
use constant GROUP => '239.255.255.250';	#Multicast Group
use constant MPORT => 1982;					#Multicast Port

sub
YeeLightBridge_Initialize
{
	my ($hash) = @_;

	$hash->{DefFn}			= "YeeLightBridge_Define";
	$hash->{UndefFn}		= "YeeLightBridge_Undef";
	$hash->{ShutdownFn}		= "YeeLightBridge_Undef";
	$hash->{ReadFn}			= "YeeLightBridge_Read";
	$hash->{NotifyFn}		= "YeeLightBridge_Notify";
	$hash->{ParseFn}		= "YeeLightBridge_Incoming";
	$hash->{SetFn}			= "YeeLightBridge_Set";
	$hash->{AttrFn}			= "YeeLightBridge_Attr";
	$hash->{AttrList}		= ""
		."defaultramp "
		."updateIP:0,1 "
		."timeout "
		."keepAlive "
		."$readingFnAttributes";
		
	# Comm with Devices
	$hash->{Clients}		= "YeeLight";
	$hash->{MatchList}		= {"1:YeeLight" => "^.*"};
	
	$hash->{Write}			= "YeeLightBridge_Write";
	
	return undef;
}

sub
YeeLightBridge_Define
{
	my ($hash, $def) = @_;
	my @a = split("[ \t][ \t]*", $def); 
	my $name = $a[0];
	
	return "$name: Only one bridge for YeeLight can be defined." if ($modules{YeeLightBridge}{defptr});

	$hash->{NAME} = $name;
	$hash->{MULTICAST_GROUP}	= GROUP;
	$hash->{MULTICAST_PORT}		= MPORT;
	$hash->{DeviceName}			= GROUP.':'.MPORT;
	
	$attr{$name}{room} = "YeeLight" if(!defined( $attr{$name}{room}));
	
	YeeLightBridgeMulticast_Close($hash);
	YeeLightBridgeMulticast_Create($hash);
	YeeLightBridgeMulticast_Send($hash);
	
	$modules{YeeLightBridge}{defptr} = $hash;
	
	return undef;
}

sub
YeeLightBridge_Undef
{
	my ($hash) = @_;
	
	RemoveInternalTimer($hash);
	YeeLightBridgeMulticast_Close($hash);
	
	delete($modules{YeeLightBridge}{defptr});
	
	return undef;
}

sub
YeeLightBridge_Set
{
	my ($hash, $name, $cmd, @val) = @_;
    
	my $list = "";
	$list .= "search ";
	
	if (lc $cmd eq 'search')
	{
		return "$name: search command doesn't work yet. Sorry :-(";
		return YeeLightBridgeMulticast_Send($hash);
	}
	
	return "Unknown argument $cmd, bearword as argument or wrong parameter(s), choose one of $list";
}

sub
YeeLightBridge_Attr
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
YeeLightBridge_Read
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $mcast = $hash->{helper}->{mcast_sock};
	
	my $buf;
	
	$mcast->recv($buf,1024);
	
	Dispatch($hash,$buf,0);
}

sub
YeeLightBridge_Notify
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	return undef;
}

sub
YeeLightBridgeMulticast_Create
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	my $mcast = IO::Socket::Multicast->new(Proto		=> 'udp',
											LocalPort	=> MPORT,
											ReuseAddr	=> 1)
											or return "Can't bind mcast: $@\n";
											
	$mcast->mcast_add(GROUP) or return "Couldn't set group: $!\n";
	
	$hash->{helper}->{mcast_sock}	= $mcast;
	$hash->{FD}						= $mcast->fileno();
	$selectlist{$hash->{NAME}}		= $hash;
	
	return undef;
}

sub
YeeLightBridgeMulticast_Send
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $dev = $hash->{DeviceName};
	
	my $sock = IO::Socket::Multicast->new(Proto=>'udp',PeerAddr=>$dev, ReuseAddr=>1);
	
	my $send = qq(M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: "ssdp:discover"\r\nST: wifi_bulb\r\n);
	$sock->mcast_send($send, $dev) or return "Couldn't send message: $!";
	Log3 $name, 4, "$name: Search with $send";
	$sock->close();
	
	return undef;
}

sub
YeeLightBridgeMulticast_Close
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	if (defined($hash->{helper}->{mcast_sock}))
	{
		$hash->{helper}->{mcast_sock}->close();
		delete($hash->{helper}->{mcast_sock});
		delete($selectlist{$name});
		delete($hash->{helper}->{mcast_FD});
	}
	
	return undef;
}

sub
YeeLightBridge_Write
{
	my ($hash,@args) = @_;
	my $name = $hash->{NAME};
	
	return undef;
}

1;
