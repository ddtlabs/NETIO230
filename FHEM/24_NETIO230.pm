# $Id$
################################################################################
#
#  24_NETIO230.pm is a FHEM Perl module to control NETIO-230 A/B/C PDU series
#
#  Copyright 2016 by dev0 (http://forum.fhem.de/index.php?action=profile;u=7465)
#
#  This file is part of FHEM.
#
#  Fhem is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 2 of the License, or
#  (at your option) any later version.
#
#  Fhem is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
################################################################################
#
# NETIO230 change log:
#
# 2016-02-14  0.5    - public release
# 2016-02-17  0.5.1  - fixed start parsing telnetRequest if disable_fork = 1
# 2016-02-21  0.5.2  - remove unnecessary debug log from _isMinMaxSI
#
#   Credit goes to:
#   - Andy Fuchs for idea and initial release of NetIO230B.pm.
#   - 3des for pointing out that there are slightly different commands in
#     different firmware version.
#
################################################################################

package main;

use strict;
use warnings;
use Data::Dumper;
use HttpUtils;
use SetExtensions;
use Blocking;

sub NETIO230_sysCmds($);
sub NETIO230_Initialize($);
sub NETIO230_Define($$);
sub NETIO230_Undef($$);
sub NETIO230_Delete($$);
sub NETIO230_Shutdown($);
sub NETIO230_Notify($$);
sub NETIO230_Set($$@);
sub NETIO230_setOnOff($$);
sub NETIO230_setSocket($$$);
sub NETIO230_setStatusRequest($);
sub NETIO230_Get($@);
sub NETIO230_Attr(@);
sub NETIO230_defineAttr($);
sub NETIO230_resetTimer($$;$);
sub NETIO230_timedStatusRequest($);
sub NETIO230_httpRequest($@);
sub NETIO230_httpRequestParse($$$);
sub NETIO230_telnetRequest($@);
sub NETIO230_doTelnetRequest($);
sub NETIO230_doTelnetRequest_Parse($);
sub NETIO230_doTelnetRequest_Aborted($);
sub NETIO230_doTelnet($@);
sub NETIO230_syntaxCheck($$@);
sub NETIO230_doSyntaxCheck($$@);
sub NETIO230_isWeekday($);
sub NETIO230_isWeekly($);
sub NETIO230_isTimeType($);
sub NETIO230_isTimeMode($);
sub NETIO230_isDisEnable($);
sub NETIO230_isBeginEnd($);
sub NETIO230_is01($);
sub NETIO230_isOnOff($);
sub NETIO230_isInteger($);
sub NETIO230_isByte($);
sub NETIO230_isManualTimer($);
sub NETIO230_isSocketAlias($);
sub NETIO230_isIPv4($);
sub NETIO230_isNetmask($);
sub NETIO230_isDateFmt($);
sub NETIO230_isTimeTFmt($);
sub NETIO230_isTimeUxFmt($);
sub NETIO230_isTimezone($);
sub NETIO230_isMinMaxSI($$$);
sub NETIO230_isSocketDefined($$);
sub NETIO230_isSocketNameDefined($$);
sub NETIO230_isFqdnIP($);
sub NETIO230_isKnownCmd($);
sub NETIO230_isTimeFmtByType($$);
sub NETIO230_isTimeWarp($$$);
sub NETIO230_checkTimeDiff($);
sub NETIO230_getTimeDiv($;$);
sub NETIO230_netioToFhemTimeFmt($);
sub NETIO230_getSocketAlias($);
sub NETIO230_isPmInstalled($$);
sub NETIO230_md5token($$);
sub NETIO230_stripHtml($);
sub NETIO230_delReadings($$;$);
sub NETIO230_modifyReadings($$$);
sub NETIO230_modifyUserInput($$$);
sub NETIO230_whoami();
sub NETIO230_log($$;$);



# ------------------------------------------------------------------------------
# returns a hash of: "pdu commands" => "readings to use"
# ------------------------------------------------------------------------------
sub NETIO230_sysCmds($)
{
  my ($hash) = @_;
  my %sysCmds = (
  "alias"               => "alias",
  "email_server"        => "smtp",
  "system_dns"          => "dns",
  "system_eth"          => "eth",
  "system_discover"     => "discover",
  "system_swdelay"      => "swdelay",
  "system_time"         => "time",
  "system_timezone"     => "timezone",
  "system_sntp"         => "ntp",
  "system_dst"          => "dst",
  "uptime"              => "uptime",
  "version"             => "firmware"
#  "system_mac"          => "mac"       # fw 4.x required
);

  # expand %sysCmds dynamically for each defined socket
  # 'port wd X' => 'socketX_wd'
  foreach my $socketNum (keys $hash->{SOCKETS}) {
    my $num = $hash->{SOCKETS}[$socketNum];
    $sysCmds{"port_wd_$num"} = "socket$num"."_wd";
    $sysCmds{"port_setup_$num"} = "socket$num"."_setup";
    $sysCmds{"port_timer_$num"."_dt"} = "socket$num"."_timer"; #label:date+time
  }

  #Log3 $hash, 5, $hash->{NAME}.": _sysCmds:\n".Data::Dumper->Dump
  #               ([ \%sysCmds ], [qw/sysCmds/]) if DEBUG;
  return %sysCmds;
}


# ------------------------------------------------------------------------------
# set cmds to use: "setCmds" => "telnet_command or http"
# ------------------------------------------------------------------------------
my %NETIO230_setCmds = (
  "off"               => "http",
  "on"                => "http",
  "socket"            => "http",
  "port"              => "http",
  "statusRequest"     => "http",
  "alias"             => "alias",
  "discover"          => "system_discover",
  "dns"               => "system_dns",
  "swdelay"           => "system_swdelay",
  "time"              => "system_time",
  "dst"               => "system_dst",
  "ntp"               => "system_sntp",
  "timezone"          => "system_timezone",
  "watchdog"          => "port_wd",
  "setup"             => "port_setup",
  "timer"             => "port_timer",
  "smtp"              => "email_server",
  "reboot"            => "reboot",
  "eth"               => "system_eth",
  "help"              => "http"
);

my %NETIO230_setParams = (
  "discover"          => "enable,disable",
  "swdelay"           => "0.1s,0.2s,0.3s,0.4s,0.5s,0.6s,0.7s,0.8s,0.9s,".
                         "1s,2s,3s,4s,5s,6s,7s,8s,9s,10s,20s,30s,45s,".
                         "1m,2m,3m,4m,5m,10m,20m,30m,45m,1h",
  "timezone"          => "UTC-12,UTC-11,UTC-10,UTC-9,UTC-8,UTC-7,UTC-6,UTC-5,".
                         "UTC-4,UTC-3,UTC-2,UTC-1,UTC,UTC+1,UTC+2,UTC+3,UTC+4,".
                         "UTC+5,UTC+6,UTC+7,UTC+8,UTC+9,UTC+10,UTC+11,UTC+12,".
                         "UTC+13,UTC+14",
  "reboot"            => "noArg",
);


# ------------------------------------------------------------------------------
# corresponding usage for set cmds: "setCmds" => "usage"
# ------------------------------------------------------------------------------
my %NETIO230_setCmdsUsage = (
  "statusRequest" => "statusRequest",
  "off"      => "<off>",
  "on"       => "<on>",
  "socket"   => "socket <num|alias> <on|off>",
  "port"     => "port <num|alias> <on|off>",
  "alias"    => "alias <name> ".
                "Note: <name> must be enclosed in quotes if spaces are used ".
                "in <name>.",
  "discover" => "discover <enable|disable>",
  "dns"      => "dns <ip>\nNote: changes only take effect after a restart",
  "swdelay"  => "swdelay <value>".
                " Note: value is tenth of a second unless suffix 's' or 'm'".
                " is used.",
  "time"     => "time <time:YYYY/MM/DD,HH:MM:SS>",
  "dst"      => "dst <enable|disable|begin|end> [<start:YYYY/MM/DD,HH:MM:SS> ".
                "<end:YYYY/MM/DD,HH:MM:SS>]",
  "ntp"      => "ntp <host:ip|fqdn>",
  "timezone" => "timezone <tz> ".
                "Note: <tz> has to be UTC[+-]0-12.",
  "watchdog" => "watchdog <socket:num|name> <mode:enable|disable> ".
                "<host:ip_to_check> <timeout:seconds> <ponDelay:seconds> ".
                "<ping_refresh:seconds> <max_retry:num> ".
                "<max_retry_poff:enable|disable> <sendEmail:enable|disable>",
  "setup"    => "setup <socket:num|name> <name:\"newname\"> ".
                "<mode:manual|timer> <interrupt_delay:seconds> ".
                "<pon_status:0|1>]",
  "timer"    => "timer <socket:num|name> <time_format:t|dt|ux> ".
                "<mode:once|daily|weekly> <on:time> <off:time> ".
                "[<weekdays:(0|1){7}>] ".
                "Note: time format t:HH:MM:SS dt:YYYY/MM/DD,HH:MM:SS ".
                "ux:xxxxxxxx (unsigned long with prefix 0x<hex>, 0<octal> or ".
                "decimal) ",
  "smtp"     => "smtp <smtp_server:ip|fqdn>",
  "reboot"   => "reboot",
  "eth"      => "eth <ip> <netmask> <gw> ".
                "Note: changes only take effect after a restart",
  "help"     => "help <".join("|", sort keys %NETIO230_setCmds).">",
);


# ------------------------------------------------------------------------------
sub NETIO230_Initialize($)
{
  my ($hash) = @_;

  $hash->{SetFn}        = "NETIO230_Set";
  $hash->{GetFn}        = "NETIO230_Get";
  $hash->{DefFn}        = "NETIO230_Define";
  $hash->{AttrFn}       = "NETIO230_Attr";
  $hash->{NotifyFn}     = "NETIO230_Notify";

  $hash->{UndefFn}      = "NETIO230_Undef";
  $hash->{ShutdownFn}	  =	"NETIO230_Shutdown";
  $hash->{DeleteFn}	    = "NETIO230_Delete";

  $hash->{AttrList}     = "do_not_notify:0,1 ".
                          "disable_fork:1,0 ".
                          "disable:1,0 ".
                          "disable_telnet:1,0 ".
                          "enable_timeEvents:1,0 ".
                          "intervalPresent ".
                          "intervalAbsent ".
                          "secureLogin:1,0 ".
#                          "telnetPort ".
                          $readingFnAttributes;
}


# ------------------------------------------------------------------------------
sub NETIO230_Define($$)  # only called when defined, not on reload.
{
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);

  my $err;
  my $usg = "Use 'define <name> NETIO230 <ip-address> ".
            "[s:<sockets>] [h:<httpPort>] [t:<telnetPort>] ".
            "[u:<username>] [p:<password>]'";

  return "Wrong syntax: $usg" if(int(@a) < 3);

  my $name = $a[0];
  my $type = $a[1];
  my $ip   = $a[2];

  #defaults
  $hash->{HTTP_PORT}   = 80;
  $hash->{TELNET_PORT} = 1234;
  $hash->{USER}        = "admin";
  $hash->{PASS}        = "admin";
  $hash->{INTERVAL}    = 300;
  @{$hash->{SOCKETS}}  = (1,2,3,4);

  if (NETIO230_isIPv4($ip)) {$hash->{HOST} = $ip}
  else {return "ERROR: [invalid IPv4 address: '$ip']"}

  foreach my $item (@a) {
    next if (not $item =~ /:/);

    my ($what,$val) = split(":",$item);
    return "ERROR: [invalid argument: '$what:'] - $usg" if ((!defined $val)
                                                                || $val eq "");
    if ($what eq "h") {
      if ($val =~ /^\d+$/ && $val > 1 && $val <= 65535) {
        $hash->{HTTP_PORT} = $val;
      } else { $err = "http port: '$val'" }

    } elsif ($val =~ /^\d+$/ && $what eq "t") {
      if ($val > 1 && $val <= 65535) {
        $hash->{TELNET_PORT} = $val;
      } else { $err = "telnet port: '$val'" }

    } elsif ($what eq "i") {
      if ($val =~ /^\d+$/ && $val >= 30) {
        $hash->{INTERVAL} = $val;
      } else { $err = "interval: '$val'" }

    } elsif ($what eq "u") {
      if ($val =~ /^[a-zA-Z\d\._-]+$/) {
        $hash->{USER} = $val;
      } else { $err = "username: '$val'" }

    } elsif ($what eq "p") {
      if ($val =~ /.+/) {
        $hash->{PASS} = $val;
      } else { $err = "password: '$val'" }

    } elsif ($what eq "s") {
      if ($val =~ /^[1-4]?+[1-4]?+[1-4]?+[1-4]?+$/ ) {
        if ($val <= 4) { # single socket
          @{$hash->{SOCKETS}} = ($val); # number -> 'array of socket-numbers'
        } else {
          @{$hash->{SOCKETS}} = split("",$val); # values -> 'array of sockets'
        }
      } else { $err = "socket(s): '$val'"}

    } else {
      $err = "argument: '$what:$val'";
    }

    return "ERROR: [invalid $err] - $usg" if (defined $err);
  }

  # internal defauls
  $hash->{helper}{useAltUrl}       = 0;
  $hash->{helper}{useAltCmd}       = 0;
  $hash->{helper}{retry}{timedout} = 0;
  $hash->{helper}{retry}{login}    = 0;
  $hash->{READINGS}{timediff}{VAL} = 0;

  # check needed perl modules
  $hash->{helper}{noPm_Telnet} = 1 if (NETIO230_isPmInstalled($hash,"Net::Telnet"));
  $hash->{helper}{noPm_MD5}    = 1 if (NETIO230_isPmInstalled($hash,"Digest::MD5"));

  Log3 $hash->{NAME}, 3, "NETIO230: opened device $name -> host:$hash->{HOST} ".
                         "httpPort:$hash->{HTTP_PORT} ".
                         "telnetPort:$hash->{TELNET_PORT} ".
                         "interval:$hash->{INTERVAL} ".
                         "socket(s):".join(",",@{$hash->{SOCKETS}});

	readingsSingleUpdate($hash, 'state', 'initialized',1);
  NETIO230_resetTimer($hash,"start",int(rand(5))+int(rand(10))/10+int(rand(10))/100 );

  return undef;
}


# ------------------------------------------------------------------------------
#UndefFn: called while deleting device (delete-command) or while rereadcfg
sub NETIO230_Undef($$)
{
  my ($hash, $arg) = @_;

  HttpUtils_Close($hash);
  BlockingKill($hash->{helper}{RUNNING_PID}) 
    if (defined($hash->{helper}{RUNNING_PID}));
  delete $modules{$hash->{TYPE}}{$hash->{NAME}}{running}
    if (defined $modules{$hash->{TYPE}}{$hash->{NAME}}{running});
  delete $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH}
    if (defined $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH});

  RemoveInternalTimer($hash);
  return undef;
}


# ------------------------------------------------------------------------------
#DeleteFn: called while deleting device (delete-command) but after UndefFn
sub NETIO230_Delete($$)
{
  my ($hash, $arg) = @_;

  Log3 $hash->{NAME}, 1, "$hash->{TYPE}: device $hash->{NAME} deleted";
  return undef;
}


# ------------------------------------------------------------------------------
#ShutdownFn: called before shutdown-cmd
sub NETIO230_Shutdown($)
{
	my ($hash) = @_;

  HttpUtils_Close($hash);
  BlockingKill($hash->{helper}{RUNNING_PID}) 
    if (defined($hash->{helper}{RUNNING_PID}));
  delete $modules{$hash->{TYPE}}{$hash->{NAME}}{running}
    if (defined $modules{$hash->{TYPE}}{$hash->{NAME}}{running});

  RemoveInternalTimer($hash);
  Log3 $hash->{NAME}, 1, "$hash->{TYPE}: device $hash->{NAME} shutdown requested";
	return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_Notify($$)
{
  my ($hash,$dev) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  my $devName = $dev->{NAME};

  return "" if(IsDisabled($name));

  my $events = deviceEvents($dev,1);
  return if( !$events );

#  if( grep(m/^(INITIALIZED|ATTR $name disable 0)$/, @{$events}) ) {
  if( grep(m/^(ATTR $name disable 0)$/, @{$events}) ) {
    NETIO230_resetTimer($hash,"start",int(rand(5))+int(rand(10))/10+int(rand(10))/100 );
    return undef;
  }
  return "";
}


# ------------------------------------------------------------------------------
sub NETIO230_Set($$@)
{
  my ($hash, $name, $cmd, @params) = @_;
  my $self = NETIO230_whoami();

  if (IsDisabled $name) {
    NETIO230_resetTimer($hash,"start");
    return;
  }

  Log3 $hash->{NAME}, 5, "$name: $self() got: hash:$hash, name:$name, cmd:$cmd, ".
                         "params:".join(" ",@params) if ($cmd ne "?");

  # get setCommands from hash
  my @cList = sort keys %NETIO230_setCmds;
  # remove telnet-commands if telnet not avail.
  if (defined $hash->{helper}{noPm_Telnet}) {
    foreach my $k (@cList) {
      delete $NETIO230_setCmds{$k} if (not $NETIO230_setCmds{$k} =~ /^http$/);
    }
  }

  if(!$NETIO230_setCmds{$cmd}) {
    my $clist = join(" ", @cList);

    my @pList = keys %NETIO230_setParams;
    foreach my $cmd (@pList) {
      $clist =~ s/$cmd/$cmd:$NETIO230_setParams{$cmd}/
    }


    my $hlist = join(",", @cList);
    $clist =~ s/help/help:$hlist/; # add all cmds as params to help cmd

    return SetExtensions($hash, $clist, $name, $cmd, @params);
  }

  # check that all necessary attrs are defined
  NETIO230_defineAttr($hash);

  # reset retry counter (used for secure login (get pwd hash) in _httpRequest_parse)
  $hash->{helper}{retry}{login} = 0;


  # do syntax check
  my $sc = NETIO230_syntaxCheck($hash,$cmd,@params);
  return $sc if (defined $sc);

  # add option to enter values in sec/min/etc...
  $params[0] = NETIO230_modifyUserInput($hash,$cmd,$params[0]);

  # replace alias socket name by socket number
  $params[0] = $hash->{helper}{aliases}{$params[0]}
    if ($cmd =~ /^(watchdog|timer|setup|socket)$/ && (not $params[0] =~ /\d/));

  if ($cmd eq "help") {
    my $usage = $NETIO230_setCmdsUsage{$params[0]};
    $usage     =~ s/Note:/\nNote:/g;
    return "Usage: set $name $usage";
  }

  elsif ($cmd =~ /statusRequest/) {
    NETIO230_setStatusRequest($hash);
    return undef;
  }

  # notify that device is unreachable
  NETIO230_log($name,"offline: set $name $cmd @params") if (defined $hash->{helper}{absent});

  if ($cmd eq "on" || $cmd eq "off") {
    NETIO230_setOnOff($hash,$cmd);
    return undef;
  }

  elsif ($cmd =~  /(socket|port)/) {
    NETIO230_setSocket($hash,$params[0],$params[1]);
    return undef;
  }

  # we got a set telnet command, but telnet is unavailable (temporary?)
  if (defined $hash->{helper}{telnetFailed}) {
    NETIO230_log($name, "Telnet not available");
    return undef;
  }

  return if (defined $hash->{TELNET} && $hash->{TELNET} eq "disabled");

  # exec all other commands via telnetRequest
  my $plist = join(" ", @params);
  Log3 $name, 5, "$name: $self() call: NETIO230_telnetRequest($hash, set $NETIO230_setCmds{$cmd} $plist)";
  NETIO230_log($name,"set $name $cmd $plist"); # value = eg. alias value: OK
  NETIO230_telnetRequest($hash,"set $NETIO230_setCmds{$cmd} $plist");

  return undef;
}

# -----------------------------------------------------------------
sub NETIO230_setOnOff($$)
{
  my ($hash,$cmd) = @_;
    my $binCmd = int($cmd eq "on");
    #prepare the sockets default parameters; 'u' means: don't touch
    my @values=("u","u","u","u");
    my @sockets = @{$hash->{SOCKETS}};
    foreach (@sockets) {
      $values[$_-1] = $binCmd;
    }
    # we have to set all 4 port at once: eg. uu1u
    NETIO230_httpRequest($hash, "set", join("",@values));
    return undef;
}

# -----------------------------------------------------------------
sub NETIO230_setSocket($$$)
{
  my ($hash,$socket,$onOff) = @_;
  # we need 0/1 instead of off/on
  my $binCmd = int($onOff eq "on");
  #prepare the sockets default parameters; 'u' means: don't touch
  my @values=("u","u","u","u");
  $values[$socket-1] = $binCmd;
  # we have to set all 4 port at once: eg. uu1u
  NETIO230_httpRequest($hash, "set", join("",@values));
  return undef;
}

# -----------------------------------------------------------------
sub NETIO230_setStatusRequest($)
{
  my ($hash) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  Log3 $name, 5, "$name: $self() got: hash:$hash";

  unless(IsDisabled($hash->{NAME}))
  {
    NETIO230_log($name,"set $name statusRequest");
    #Timer will be restarted at end of NETIO230_httpRequest again.
    NETIO230_resetTimer($hash,"stop");
    NETIO230_httpRequest($hash,"get");
    NETIO230_telnetRequest($hash,"statusRequest")
      if (not defined $hash->{TELNET} || (defined $hash->{TELNET} && $hash->{TELNET} ne "0"));
  }
  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_Get($@)
{
  my ($hash, @a) = @_;
  return "argument is missing" if(int(@a) != 2);

  my $reading = $a[1];
  my $ret;

  if(exists($hash->{READINGS}{$reading})) {
    if(defined($hash->{READINGS}{$reading})) {
      return $hash->{READINGS}{$reading}{VAL};
    }
    else {
      return "no such reading: $reading";
    }
  }

  else {
    $ret = "unknown argument $reading, choose one of";
    foreach my $reading (sort keys %{$hash->{READINGS}}) {
      $ret .= " $reading:noArg" if ($reading ne "firmware");
    }
    return $ret;
  }
}


# ------------------------------------------------------------------------------
sub NETIO230_Attr(@)
{
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};
  my $ret = undef;

  # InternalTimer will be called from notifyFn if disabled = 0
  if ($aName eq "disable") {
    $ret="0,1" if ($cmd eq "set" && not $aVal =~ /(0|1)/);
    if ($cmd eq "set" && $aVal eq "1") {
      NETIO230_log($name,"device is disabled", "NOTICE: ");
      NETIO230_delReadings($hash,"all",1);
      readingsSingleUpdate($hash, "state", "disabled",1);
    }
  }

  if ($aName eq "disable_telnet") {
    if ($cmd eq "set") {
      if ($aVal eq "1") {
        $hash->{TELNET} = "disabled";
        NETIO230_delReadings($hash,"telnet",1);
      }
      elsif ($aVal eq "0") {
        delete $hash->{TELNET} if (defined $hash->{TELNET});
      }
      else {
        $ret ="0,1"
      }
    }
    if ($cmd eq "del") {
        delete $hash->{TELNET} if (defined $hash->{TELNET});
    }

  }
    elsif ($aName eq "disable_fork") {
    $ret = "0,1" if ($cmd eq "set" && not $aVal =~ /(0|1)/)
  }

    elsif ($aName eq "enable_timeEvents") {
    $ret = "0,1" if ($cmd eq "set" && not $aVal =~ /(0|1)/)
  }

  elsif ($aName eq "intervalPresent") {
    $ret = ">=30" if ($cmd eq "set" && int($aVal) < 30)
  }

  elsif ($aName eq "intervalAbsent") {
    $ret = ">=30" if ($cmd eq "set" && int($aVal) < 30)
  }

  elsif($aName eq "secureLogin") {
    if($cmd eq "set") {
      if (defined $hash->{helper}{noPm_MD5}) {
        $ret = "perl modul Digest::MD5 must be installed";
      }
      elsif (int($aVal) != 1 && int($aVal) != 0) {
        $ret="0,1";
      }
    }
    if($cmd eq "del") {
      #nothing
    }
  }

  if (defined $ret) {
    NETIO230_log($name,"attr $aName $aVal != $ret");
    return "$aName must be: $ret";
  }
  else {
    #NETIO230_log($name,"attr $name $aName $aVal");
  }

  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_defineAttr($)
{
  my $name = $_[0]->{NAME};

  my %as = (
#    "disable"             => 0,
#    "disable_fork"        => 0,
#    "disable_telnet"      => 0,
#    "enable_timeEvents"  => 1,
    "secureLogin"         => 1
#    "intervalPresent"     => 300,
#    "intervalAbsent"      => 300,
#    "telnetPort"          => 1234,
  );

  my @al = sort keys %as;
  foreach my $a (@al) {
    if(!defined($attr{$name}{$a})) {
	  	$attr{$name}{$a} = $as{$a};
      NETIO230_log($name, "attr $name $a $as{$a}", "NOTICE: ");
    }
  }

  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_resetTimer($$;$)
{
  my ($hash,$cmd,$interval) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  return if (IsDisabled $name);

  RemoveInternalTimer($hash);

  Log3 $hash->{NAME}, 5, "$name: $self() call: RemoveInternalTimer($hash)";

  if ($cmd ne "stop") {
    if (defined $interval) {
    }
    elsif (defined $hash->{helper}{absent} && defined $attr{$name}{intervalAbsent})
      { $interval = $attr{$name}{intervalAbsent}+rand(6)-3; }
    elsif (!defined $hash->{helper}{absent} && defined $attr{$name}{intervalPresent})
      { $interval = $attr{$name}{intervalPresent}+rand(6)-3; }
    else
      { $interval = $hash->{INTERVAL}+rand(6)-3; }

    Log3 $name, 5, "$name: $self() InternalTimer(+$interval,\"NETIO230_timedStatusRequest\",".' $hash, 0)';
    InternalTimer(gettimeofday()+$interval,"NETIO230_timedStatusRequest", $hash, 0);
  }
  else {
    Log3 $name, 5, "$name: $self() InternalTimer() deleted";
  }

  return undef;
}
# ------------------------------------------------------------------------------
sub NETIO230_timedStatusRequest($) { NETIO230_Set($_[0],$_[0]->{NAME},"statusRequest","") }


# ------------------------------------------------------------------------------
# --- set/get status of sockets via http
# ------------------------------------------------------------------------------
sub NETIO230_httpRequest($@)
{
  my ($hash, $cmd, $arg) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());

  my $baseUrl  = "http://$hash->{HOST}:$hash->{HTTP_PORT}/tgi/control.tgi?"; #default url
  my $pwd      = $hash->{PASS}; # plain password login by default
  my $urlCmd   = "login=p:";    # plain password login by default (=p)


  $arg = "" if (!defined $arg);
  Log3 $name, 5, "$name: $self() got: cmd:$cmd, arg:$arg";

  # used in case of an error of HttpUtils_NonblockingGet
  $hash->{helper}{httpReq}{cmd} = $cmd; # used to recall
  $hash->{helper}{httpReq}{arg} = $arg; # same

  # secure login
  if (defined $attr{$hash->{NAME}}{secureLogin}
  && $attr{$hash->{NAME}}{secureLogin} == 1) {
    if (defined $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH}) {
      $pwd = NETIO230_md5token($hash,
                     "$modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH}");
      $urlCmd  = "login=c:"; # =c -> secure login
    }
    else { # request new token from device
      $cmd    = "hash";
      $urlCmd = "hash=hash";
      NETIO230_log($name,"request pwdhash");
    }
  }

   my $urlParam = "";
  if ($cmd eq "set") {
    $urlParam = $hash->{USER}.":".$pwd."&port=".$arg; # port=u1uu
  }
  elsif ($cmd eq "get") {
    $urlParam = $hash->{USER}.":".$pwd."&port=list";  # list -> get status
  }

  # try different url
  $baseUrl  =~ s/tgi/cgi/g    if ($hash->{helper}{useAltUrl} == 1);
  # try different cmds...
  $urlCmd   =~ s/login=/l=/g  if ($hash->{helper}{useAltCmd} == 1);
  $urlParam =~ s/port=/p=/g   if ($hash->{helper}{useAltCmd} == 1);
  $urlParam =~ s/list/l/g     if ($hash->{helper}{useAltCmd} == 1);

  my $param = {
              url         => $baseUrl.$urlCmd.$urlParam,
              timeout     => 5,
              keepalive   => 0,
              httpversion => "1.0",
              hideurl     => 0,
              method      => "GET",
              hash        => $hash,
              callback    =>  \&NETIO230_httpRequestParse,
              cmd         => $cmd,     # Pass throught to parseFN
              arg         => $arg      # Pass throught to parseFN
              };

  Log3 $name, 5, "$name: $self() url: $baseUrl$urlCmd$urlParam";
  Log3 $name, 5, "$name: $self() call: HttpUtils_NonblockingGet($param)";
  $modules{$hash->{TYPE}}{$hash->{NAME}}{running}{http} = 1;
  HttpUtils_NonblockingGet($param);

  return undef;
}


# ------------------------------------------------------------------------------
# --- parse _httpStatus response
# ------------------------------------------------------------------------------
sub NETIO230_httpRequestParse($$$)
{
  my ($param, $err, $data) = @_;
  my $hash = $param->{hash};
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  return if (!defined $modules{$hash->{TYPE}}{$hash->{NAME}}{running}{http});

  Log3 $name, 5, "$name: $self() got: ".
                 "cmd:$param->{cmd}, arg:$param->{arg}, err:$err, data:$data";

# --- HttpUtils_NonblockingGet Error handling ----------------------------------
  if($err ne "")
  {
    Log3 $hash->{NAME}, 5, "$name: $self() -> err:$err";

    # try an alternate url: eg. newer firmware uses cgi instead of tgi
    if ($err =~/empty answer received/ #err msg from HttpUtils_NonblockingGet
      && $hash->{helper}{useAltUrl} < 1) { #inc if there are more alt. urls
        NETIO230_log($name,"alternate HTTP URL $hash->{helper}{useAltUrl}");
        # call _httpRequest again and use alternate url
        # helper is needed for secureLogin
        $hash->{helper}{useAltUrl}++;
        NETIO230_httpRequest($hash, $hash->{helper}{httpReq}{cmd},
                              $hash->{helper}{httpReq}{arg});
        return undef;
    }

    # err msg from HttpUtils_NonblockingGet, occurs eg. when too many instances
    # try to connect at the same time.
    elsif ($err =~/timed out/ && $hash->{helper}{retry}{timedout} < 3) {
        $hash->{helper}{retry}{timedout}++;
        NETIO230_log($name,"retry timed out ".
                            "($hash->{helper}{retry}{timedout}): ".
                            "$hash->{helper}{httpReq}{cmd} ".
                            "$hash->{helper}{httpReq}{arg}");
        # just retry up to 2 times, helper is needed for secureLogin
        NETIO230_httpRequest($hash, $hash->{helper}{httpReq}{cmd},
                                    $hash->{helper}{httpReq}{arg});
        return undef;
    }

    # exec just once in case of an error
    if (!defined $hash->{helper}{absent}) {
      $hash->{helper}{absent} = 1;
      readingsSingleUpdate($hash, "presence", "absent",1);
      Log3 $name, 5, "$name: $self() call: ".
                     "NETIO230_delReadings($hash,\"http\")";
      NETIO230_log($name,$err);
      #select(undef, undef, undef, 0.005); # delay of 5ms
      NETIO230_delReadings($hash,"http");
    }
    else {
      readingsSingleUpdate($hash, "_lastNotice", "[$err]",0);
    }
  }

# --- Real data or http error codes from device
  elsif($data ne "")
  {
    Log3 $hash->{NAME}, 5, "$name: $self() -> data ne \"\"";
    if (defined $hash->{helper}{absent}) {
      delete $hash->{helper}{absent};
      NETIO230_log($name,"OK: http");
    }
    $hash->{helper}{retry}{timedout} = 0; #reset retry counter

    # Presence reading
    if (defined $hash->{READINGS}{presence}{VAL}
    && $hash->{READINGS}{presence}{VAL} ne "present") {
      readingsSingleUpdate($hash,"presence","present",1);
    }

    # Any 55X error occurred
    if ($data =~/55\d [A-Z]+/) {

      if ($data =~ /551 INVALID PARAMETR/)
      {
        # try alternate commands
        if ($hash->{helper}{useAltCmd} < 1) {
          $hash->{helper}{useAltCmd}++;
          Log3 $name, 5, "$name: $self() trying alternate Commands: cmd:$param->{cmd} ".
                         "arg:$param->{arg} alt:$hash->{helper}{useAltCmd}";
          NETIO230_log($name,"alternate HTTP CMD $hash->{helper}{useAltCmd}");
          NETIO230_httpRequest($hash, $param->{cmd}, $param->{arg});
          return undef;
        }
        # alt cmds did not work :-(
        $hash->{helper}{useAltCmd} = 0;
        # $hash->{_lastERROR} = "Unkonwn device command set";
      }

      if ($data =~ /553 INVALID LOGIN/)
      {
        if (defined $attr{$hash->{NAME}}{secureLogin}
        && $attr{$hash->{NAME}}{secureLogin} == 1)
        {
          # when two or more device try to connect at the time -> retry up to 2x
          if ($hash->{helper}{retry}{login} < 2) {
            if ($hash->{helper}{retry}{login}== 0) { #del key to get a new hash
              delete $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH}
                if (defined $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH});
            }
            if ($hash->{helper}{retry}{login} >0) {
              NETIO230_log($name,"553 retry login ".
                                  "($hash->{helper}{retry}{login})");
            }
            $hash->{helper}{retry}{login}++;
            NETIO230_httpRequest($hash, $param->{cmd}, $param->{arg});
            return undef;
          }
        } #secureLogin
      } #if 553

      NETIO230_log($name,$data);
      NETIO230_delReadings($hash,"http") if (defined $hash->{READINGS}{state});
      $hash->{helper}{retry}{login} = 0;

    } #if 55x

# --- There seems to be no error - start parsing result ------------------------
#--- get
    elsif ($param->{cmd} eq "get") {
      Log3 $name, 5, "$name: $self() -> get";
      $data = NETIO230_stripHtml($data);
      my @values=split(/ */,$data); # split received data into array (1 0 0 0)
      my $state = "";
      my @sockets = @{$hash->{SOCKETS}};  # get state for each defined socket
      readingsBeginUpdate($hash);
      foreach (@sockets) {
        my $val = NETIO230_modifyReadings($hash,"socket",$values[$_-1]);
        readingsBulkUpdate($hash,"socket$_",$val);
#        readingsBulkUpdate($hash,"socket$_",$values[$_-1]);
        $state .= $values[$_-1];
      }

      # state will be "on" if any socket is on or "off" if all socket are off
      if ($state =~ /1/) {$state = "on"} else {$state = "off"};
      readingsBulkUpdate($hash,"state",$state);
      readingsEndUpdate($hash, 1);
      NETIO230_log($name,"get $name state: $state");
      delete $hash->{helper}{httpReq};
      $hash->{helper}{retry}{login} = 0;
    }

#--- set
    elsif ($param->{cmd} eq "set") {
      Log3 $name, 5, "$name: $self() -> set";
      $data = NETIO230_stripHtml($data);
      Log3 $name, 5, "$name: $self() data:$data";
      if ($data =~ /250 OK/) {
        my $s = $param->{arg};
        if ($s =~ /1/) {$s = "on"} else {$s = "off"}
        NETIO230_log($name,"set $name $s: OK");
      }
      else {
        NETIO230_log($name,"set $name (on|off): failed response:$data");
        Log3 $name, 5, "$name: $self() unexpected respose data:$data";
      }
      # get new socket state from device.
      NETIO230_httpRequest($hash,"get");
    }

#--- hash
    elsif ($param->{cmd} eq "hash") {  # get pwd hash from device (secureLogin)
      Log3 $name, 5, "$name: $self() -> hash";
      $data = NETIO230_stripHtml($data);
      $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH} = $data;
      #$hash->{PWDHASH} = $data; # no more needed but informational
      Log3 $name, 5, "$name: $self() hash: \"$data\"";
      # call _httpRequest again with orig. $cmd and $arg
      NETIO230_log($name,"got pwdhash");
      NETIO230_httpRequest($hash,$hash->{helper}{httpReq}{cmd},$param->{arg});
      return undef;
    }

  }

  if (defined $modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH}) {
     Log3 $name, 5, "$name: $self() PWDHASH:".
                    "$modules{$hash->{TYPE}}{$hash->{HOST}}{PWDHASH}";
  }
  Log3 $name, 5, "$name: $self() call: NETIO230_resetTimer($hash,\"start\")";
  NETIO230_resetTimer($hash,"start");
  return undef;
}


# ------------------------------------------------------------------------------
# --- NETIO230_telnetRequest (split between blocking and non-blocking telnet) --
# ------------------------------------------------------------------------------
sub NETIO230_telnetRequest($@)
{
  my ($hash,$param) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  Log3 $name, 5, "$name: $self() return: undef (noTelNetINstalled)"
   if (defined $hash->{helper}{noPm_Telnet});
  return undef if (defined $hash->{helper}{noPm_Telnet});

  $modules{$hash->{TYPE}}{$hash->{NAME}}{running}{telnet} = 1;

  my $host =  $hash->{HOST};
#  ($host) = split(/:/,$host,0);
  Log3 $name, 5, "$name: $self() got: $param";

  if (defined $attr{$hash->{NAME}}{disable_fork}
  && ($attr{$hash->{NAME}}{disable_fork} == 1))
  {
    Log3 $name, 5, "$name: $self() call: ".
                   "NETIO230_doTelnetRequest($hash->{NAME}|$host|$param)";
    my $ret = NETIO230_doTelnetRequest($hash->{NAME}."|".$host."|".$param);
    Log3 $name, 5, "$name: $self() call: NETIO230_doTelnetRequest_Parse($ret)";
    NETIO230_doTelnetRequest_Parse($ret);
  }
  else
  {
     Log3 $name, 5, "$name: $self() call: ".
       "BlockingCall(\"NETIO230_doTelnetRequest\", $hash->{NAME}|$host|$param)";
    unless(exists($hash->{helper}{RUNNING_PID})){
      $hash->{helper}{RUNNING_PID} = BlockingCall(
      "NETIO230_doTelnetRequest", $hash->{NAME}."|".$host."|".$param,
      "NETIO230_doTelnetRequest_Parse", 10,
      "NETIO230_doTelnetRequest_Aborted", $hash);
    Log3 $name, 5, "$name: $self() running PID: $hash->{helper}{RUNNING_PID}";
    }
  }
  return undef;
}


# ------------------------------------------------------------------------------
# --- get/set via telnet
# ------------------------------------------------------------------------------
sub NETIO230_doTelnetRequest($)
{
  my ($string) = @_;
  my ($name, $host, $param) = split("\\|", $string);
  my ($what,$command) = split(" ",$param,2);
  my $self = NETIO230_whoami();
  my $hash = $defs{$name};
  my $tRet;
  my $ret;

  Log3 $name, 5, "$name: $self() got: $string";

  my $tPort = "1234"; # default Netio setting
  $tPort = $hash->{TELNET_PORT};
  my $telnet = new Net::Telnet (Port => $tPort, Timeout=>4, Errmode=>'return');
   Log3 $name, 5, "$name: $self() call: NETIO230_doTelnet($hash,$telnet,\"open\")";
  # --- open telnet connect
  $tRet = NETIO230_doTelnet($hash,$telnet,"open");
  if ($tRet ne "OK") {
    Log3 $name, 5, "$name: $self() return: $name||failed::$tRet";
    return $name."||failed||".$tRet;
  }

  Log3 $name, 5, "$name: $self() call: NETIO230_doTelnet($hash,$telnet,\"$what\")";
  # --- do telnet action
  if ($what eq "statusRequest") #GET all system parameters
  {
    my %rets = NETIO230_doTelnet($hash,$telnet,"statusRequest");
    my @rList = sort keys %rets;
    $tRet = "";
    foreach my $item (@rList) {
      $tRet .= $item."::".$rets{$item}."|";
    }
    $tRet =~ s/\|$//; # remove trailing pipe
    $ret = $name."||statusRequest||".$tRet;
  }
  elsif ($what eq "get") #GET system parameters
  {
    $tRet = NETIO230_doTelnet($hash,$telnet,"get",$command);
    $ret = $name."||getCmdVal||".$tRet;
  }
  elsif ($what eq "set") # SET system parameter
  {
    $tRet = NETIO230_doTelnet($hash,$telnet,"set",$command);
    $ret = $name."||setCmd||"."$command: $tRet"; #eg. alias value: OK
  }

  # --- close telnet connect
  $tRet = NETIO230_doTelnet($hash,$telnet,"close");
  return $ret;
}


# ------------------------------------------------------------------------------
sub NETIO230_doTelnetRequest_Parse($)
{
  my ($string) = @_;
  return unless(defined($string));

  my ($name, $what, $value) = split("\\|\\|", $string, 3);
  my $hash = $defs{$name};
  my $self = NETIO230_whoami();

  return if (!defined $modules{$hash->{TYPE}}{$hash->{NAME}}{running}{telnet});

  Log3 $name, 5, "$name: $self() got: $string";
  delete($hash->{helper}{RUNNING_PID}) if (defined $hash->{helper}{RUNNING_PID});

  # failed while open port or login to device
  if ($what eq "failed") {
    Log3 $name, 5, "$name: $self() -> failed";
    if (!defined $hash->{helper}{telnetFailed}) {
      NETIO230_log($name,"$value");
      $hash->{helper}{telnetFailed} = 1;
      NETIO230_delReadings($hash,"telnet");
    }
  return undef;
  }

  elsif ( defined $hash->{helper}{telnetFailed} ) {
    delete $hash->{helper}{telnetFailed};
    NETIO230_log($name,"OK: telnet");
  }

  Log3 $name, 5, "$name: $self() -> $what";

  if ($what eq "statusRequest")
  {
    my @values = split("\\|",$value);
    my @unknownCmds;
    my %timeReadings;
    readingsBeginUpdate($hash);
    foreach my $item (@values)
    {
      my ($reading,$val) = split("::",$item);
      if ($val =~ /^5\d{2} [A-Z]+/ && not defined $hash->{helper}{UNKNOWN}{$val})
      {
        $val =~ s/_/ /g;
        $hash->{helper}{UNKNOWN}{$val} = 1;
        push(@unknownCmds,$val);
      }
      elsif (not $val =~ /^5\d{2} [A-Z]+/)
      {
        $val = NETIO230_modifyReadings($hash,$reading,$val); # modify readingsVal before update (eg. SI)

        # update readings with event
        if ($reading eq "firmware") {
          $hash->{FIRMWARE} = $val }

        elsif (not($reading =~ /^time|uptime$/)
        || (defined $attr{$name}{enable_timeEvents} 
        && $attr{$name}{enable_timeEvents} eq "1")) 
          {readingsBulkUpdate($hash, $reading, $val)}

        # insert into hash for processing without event below
        else { #if ($reading =~ /^time|uptime$/ && $attr{$name}{enable_timeEvents} eq "1")
          $timeReadings{$reading} = $val; }

      }
    } #foreach
    readingsEndUpdate($hash, 1);

    # update readings without event
    if (!defined $attr{$name}{enable_timeEvents} || $attr{$name}{enable_timeEvents} eq "0") {
      my @rList = (keys %timeReadings);
      foreach my $reading (@rList) {
        readingsSingleUpdate($hash, $reading, $timeReadings{$reading}, 0)
      }
    }

    # if there is any unknown command: log once for users
    foreach my $unknown (@unknownCmds) {
        Log3 $name, 5, "$name: $self() UNKNOWN: $unknown";
        NETIO230_log($name,"$unknown");
    }
    NETIO230_getSocketAlias($hash);
    NETIO230_checkTimeDiff($hash);
  }

  elsif ($what eq "getCmdVal")
  {
    my ($reading,$val) = split(":-:",$value);

    # label command as unavailable
    if ($val =~ /^5\d{2} [A-Z]+/ && not defined $hash->{helper}{UNKNOWN}{$val})
    {
      $val =~ s/_/ /g;
      $hash->{helper}{UNKNOWN}{$val} = 1;
      NETIO230_log($name,"$val");
    }
    # no error occurred -> update reading
    elsif (not $val =~ /^5\d{2} [A-Z]+/)
    {
      Log3 $name, 5, "$name: $self() call: readingsSingleUpdate($hash, $reading, $val, 1)";
      $val = NETIO230_modifyReadings($hash,$reading,$val); # modify readingsVal before update
      readingsSingleUpdate($hash, $reading, $val, 1);
    }
    NETIO230_log($name,"get $name $reading: $val");
  }

  # response from set cmd - build new get command for request
  elsif ($what eq "setCmd")
  {
    my $tState;
    ($value,$tState) = split(": ",$value);# split value from result (ok|failed)
    return undef if ($value =~ /reboot/); # reboot was initiated. No get here.

    # convert set cmd to get cmd -> request new val from device after set
    if ($value =~ /^port/) {
      my ($c,$p) = split(" ",$value,0); # cut disturbing parameters for get
      $value = $c."_".$p;
      # timer needs an additional parameter, always use dt to get date+time
      $value .= "_dt" if ($value =~ /^port.timer/); #label:date+time
    }
    else { # there is a single word command, just cut unnecessary parameters
      ($value) = split(" ",$value,0);
    }

    Log3 $name, 5, "$name: $self() call: NETIO230_telnetRequest($hash,\"get $value\")";

    NETIO230_telnetRequest($hash,"get $value");
  }

  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_doTelnetRequest_Aborted($)
{
  my ($hash) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  return if (!defined $modules{$hash->{TYPE}}{$hash->{NAME}}{running}{telnet});
  Log3 $name, 5, "$name: $self() got: $hash";
  delete($hash->{helper}{RUNNING_PID});
  NETIO230_log($name,"failed: BlockingCall");
  NETIO230_resetTimer($hash,'start');
  return undef;
}


# ------------------------------------------------------------------------------
# --- telnet functions: open, single, bulk, close (return: error code or data)
# ------------------------------------------------------------------------------
sub  NETIO230_doTelnet($@)
{
  my ($hash,$telnet,$what,$cmd) = @_;  #$what = open,single,bulk,close
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  my $err;
  my $line = "";
  my $host =  $hash->{HOST};
#  ($host) = split(/:/,$host,0);

  if (!defined $cmd) {$cmd=""}
  Log3 $name, 5, "$name: $self() got: hash:$hash, telnet:$telnet, what:$what, cmd:$cmd";

  if ($what eq "open")
  {
    $telnet->open($host);
    unless($telnet->waitfor('/100.HELLO /i')) {
      $err = "failed: no telnet prompt";
      Log3 $name, 5, "$name: $self() return: $err";
      return $err;
    }
    $line = $telnet->getline();
    Log3 $name, 5, "$name: $self() -> login";

    if (defined $attr{$hash->{NAME}}{secureLogin}
      && ($attr{$hash->{NAME}}{secureLogin} == 1)
      && (!defined $hash->{helper}{noPm_MD5})) {
        my ($t) = split(" ",$line,0);
        my $token = NETIO230_md5token($hash,$t);
        $telnet->print("clogin $hash->{USER} $token");
    }
    else {
      $telnet->print("login $hash->{USER} $hash->{PASS}");
    }

    unless($telnet->waitfor('/250 OK/i')) {
      $err = $telnet->getline();
      Log3 $name, 5, "$name: $self() return: $err";
      return "failed: $err";
    }
    $line = $telnet->getline();
    Log3 $name, 5, "$name: $self() return: OK";
    return "OK";
  }

  elsif ($what eq "set") #set single value
  {
    my $tCmd = $cmd; $tCmd =~ s/_/ /; # use space instead of _ for telnet cmds
    Log3 $name, 5, "$name: $self() call: $telnet->print($tCmd)";
    unless($telnet->print($tCmd)) {return "failed: could not exec $cmd"}
    $line = $telnet->getline();
    $line =~s/\n//;
    $line =~s/^250 //;
    Log3 $name, 5, "$name: $self() return: $line";
    return $line; # returns "OK" or an error
  }


  elsif ($what eq "get") #get single value
  {
    my $tCmd = $cmd; $tCmd =~ s/_/ /g; # use space instead of _ for telnet cmds
    Log3 $name, 5, "$name: $self() call: $telnet->print($tCmd)";
    unless($telnet->print($tCmd)) {return "failed: could not exec $cmd"}
    $line = $telnet->getline();
    Log3 $name, 5, "$name: $self() getline:$line $cmd:$cmd";
    # return error in occurred, should not happen because our syntax check
    return "_lastNotice:-:$line" if (not $line =~ /^250/);
    $line =~s/\n//;
    $line =~s/^250 //;
    my %sysCmds = NETIO230_sysCmds($hash);
    # always use "dt" param to get date+time from device
    $cmd =~ s/$2$/_dt/ if $cmd =~ /^port_timer_(\d)(_t|_ux)$/; #label:date+time
    Log3 $name, 5, "$name: $self() sysCmds{$cmd}: ".$sysCmds{$cmd};
    my $reading = $sysCmds{$cmd};
    Log3 $name, 5, "$name: $self() return: $reading:-:$line";
    return "$reading:-:$line";
  }

  elsif ($what eq "statusRequest") #get all values
  {
    my %rets;
    my %sysCmds = NETIO230_sysCmds($hash);
    my @cList = sort keys %sysCmds;
    foreach my $item (@cList)
    {
      my $tCmd = $item; $tCmd =~ s/_/ /g; # use space instead of _ for telnet cmds
      Log3 $name, 5, "$name: $self() call: $telnet->print($tCmd)";
      unless($telnet->print($tCmd)) {return $telnet->getline()};
      $line = $telnet->getline();
      $line =~s/\n//;
      $line =~s/^250 //;
      # check for any error: eg. "502 UNKNOWN COMMAND"
      if ($line =~ /^5\d{2} [A-Z]+/) {
        $line .= ": $item";
      }
      Log3 $name, 5, "$name: $self() >item:$item line:$line";
      $rets{$sysCmds{$item}} = $line;
    }
    return %rets;
  }

  elsif ($what eq "close")
  {
    $telnet->close;
  }

  else
  {
    Log3 $name, 5, "$name: $self() ??? unexpected what:$what";
  }
}


# ------------------------------------------------------------------------------
# --- systax check -------------------------------------------------------------
# ------------------------------------------------------------------------------

sub NETIO230_syntaxCheck($$@)
{
  my ($hash,$cmd,@p) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  my $sc = NETIO230_doSyntaxCheck($hash,$cmd,@p);
  if (defined $sc) {
    my ($e_txt,$e_p) = split("\\|\\|",$sc); # eg. "Unknown command:||cmd"
    my $err = "Wrong syntax: 'set $name $cmd ".join(" ", @p)."' - $e_txt $e_p";
    NETIO230_log($name,$err);
    my $usage = "set $name $NETIO230_setCmdsUsage{$cmd}";
    $usage =~ s/<dev>/$name/g;
    Log3 $name, 2, "$name: USAGE: $usage";
    $usage =~ s/Note:/\nNote:/g;
    return "$err\nUsage: $usage";
  }
  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_doSyntaxCheck($$@)
{
  no warnings;
  my ($hash,$cmd,@p) = @_;

  my $e_tma    = "Touch too much:";
  my $e_cmd    = "Unknown command:";
  my $e_moi    = "Invalid or missing";
  my $e_ip     = "$e_moi IPv4 address:";
  my $e_fqdn   = "$e_moi IPv4 address / fqdn:";
  my $e_nm     = "$e_moi netmask:";
  my $e_dFmt   = "$e_moi date format:";
  my $e_wFmt   = "$e_moi weekday format:";
  my $e_sName  = "$e_moi quote enclosed socket alias:";
  my $e_socket = "$e_moi socket num|name:";
  my $e_tz     = "$e_moi time zone. Has to be UTC[+-]0-12:";
  my $e_dhcp   = "$e_moi mode. Must be \"manual\" or \"dhcp\":";
  my $e_enable = "$e_moi mode. Must be enable or disable:";
  my $e_manual = "$e_moi mode. Must be \"manual\" or \"timer\":";
  my $e_eeed   = "$e_moi mode. Must be \"enable\", \"disable\", \"begin\" or \"end\":";
  my $e_01     = "$e_moi argument. Must be \"0\" or \"1\":";
  my $e_OnOff  = "$e_moi argument. Must be \"on\" or \"off\":";
  my $e_int    = "$e_moi argument. Must be an integer (0-65535):";
  my $e_byte   = "$e_moi argument. Must be an integer (0-255):";
  my $e_intsm  = "$e_moi argument. Must be an integer or time in s or m:";
  my $e_tRange = "$e_moi time range. Must be \"once\", \"daily\" or \"weekly\":";
  my $e_tType  = "$e_moi time mode. Must be \"t\", \"dt\" or \"ux\":";
  my $e_tPast  = "Let's do the time warp again...";
  my $e_usage  = "";

  if ($p[0] eq "?") {
  return "||";

  } elsif ($cmd =~ /^(statusRequest|reboot|on|off)$/) {
    return undef ;

  } elsif ($cmd eq "socket") {
    return "$e_socket||'$p[0]'" if (not NETIO230_isSocketNameDefined($hash,$p[0]));
    return "$e_OnOff||'$p[1]'"  if (not NETIO230_isOnOff($p[1]));
    return "$e_tma||'$p[2]'"    if (int(@p) > 2);

  } elsif ($cmd eq "time") {
    return "$e_dFmt||'$p[0]'"   if (not NETIO230_isDateFmt($p[0]));
    return "$e_tma||'$p[1]'"    if (int(@p) > 1);

  } elsif ($cmd eq "smtp") {
    return "$e_fqdn||'$p[0]'"   if (not NETIO230_isFqdnIP($p[0]));
    return "$e_tma||'$p[1]'"    if (int(@p) > 1);

  } elsif ($cmd eq "dns") {
    return "$e_ip||'$p[0]'"     if (not NETIO230_isIPv4($p[0]));
    return "$e_tma||'$p[1]'"    if (int(@p) > 1);

  } elsif ($cmd eq "discover") {
    return "$e_enable||'$p[0]'" if (not NETIO230_isDisEnable($p[0]));
    return "$e_tma||'$p[1]'"    if (int(@p) > 1);

  } elsif ($cmd eq "swdelay") {
    return "$e_intsm||'$p[0]'"  if (not NETIO230_isMinMaxSI($p[0],0,65535));
    return "$e_tma||'$p[1]'"    if (int(@p) > 1);

  } elsif ($cmd eq "timezone") {
    return "$e_tz||'$p[0]'"     if (not NETIO230_isTimezone($p[0]));
    return "$e_tma||'$p[1]'"    if (int(@p) > 1);

  } elsif ($cmd eq "dst") {
    return "$e_eeed||'$p[0]'"   if (not(NETIO230_isDisEnable($p[0])) && not(NETIO230_isBeginEnd($p[0])));
    return "$e_tma||'$p[1]'"    if (    NETIO230_isDisEnable($p[0]) && (defined ($p[1])));
    return "$e_dFmt||'$p[1]'"   if (    NETIO230_isBeginEnd($p[0]) && not(NETIO230_isDateFmt($p[1]))); #date

  } elsif ($cmd eq "ntp") {
    return undef                if ($p[0] eq "disable");
    return "$e_enable||'$p[0]'" if (not NETIO230_isDisEnable($p[0]));
    return "$e_fqdn||'$p[1]'"   if (not NETIO230_isFqdnIP($p[1]));

  } elsif ($cmd eq "setup") {
    return "$e_socket||'$p[0]'" if (not NETIO230_isSocketNameDefined($hash,$p[0]));
    return "$e_sName||'$p[1]'"  if (not NETIO230_isSocketAlias($p[1]));
    return "$e_manual||'$p[2]'" if (not NETIO230_isManualTimer($p[2]));
    return "$e_int||'$p[3]'"    if (not NETIO230_isInteger($p[3])); #interrupt delay
    return "$e_01||'$p[4]'"     if (not NETIO230_is01($p[4]));      #pon
    return "$e_tma||'$p[5]'"    if (int(@p) > 5);

  } elsif ($cmd eq "watchdog") {
    return "$e_socket||'$p[0]'" if (not NETIO230_isSocketNameDefined($hash,$p[0]));
    return undef                if (    NETIO230_isDisEnable($p[1]) && (int(@p) == 2));
    return "$e_ip||'$p[2]'"     if (not NETIO230_isIPv4($p[2]));      #ip to check
    return "$e_byte||'$p[3]'"   if (not NETIO230_isByte($p[3]));      #timeout      <=255
    return "$e_int||'$p[4]'"    if (not NETIO230_isInteger($p[4]));   #pon delay    <=65535
    return "$e_byte||'$p[5]'"   if (not NETIO230_isByte($p[5]));      #ping refresh <=255
    return "$e_byte||'$p[6]'"   if (not NETIO230_isByte($p[6]));      #max retry    <=255
    return "$e_enable||'$p[7]'" if (not NETIO230_isDisEnable($p[7])); #send email
    return "$e_enable||'$p[8]'" if (not NETIO230_isDisEnable($p[8])); #send email
    return "$e_tma||'$p[9]'"   if (int(@p) > 9);
    return "$e_tma||'$p[2]'"    if ($p[1] eq "disable" && (int(@p) > 2));

  } elsif ($cmd eq "timer") {
    return "$e_socket||'$p[0]'" if (not NETIO230_isSocketNameDefined($hash,$p[0]));
    return "$e_tType||'$p[1]'"  if (not NETIO230_isTimeType($p[1]));
    return "$e_tRange||'$p[2]'" if (not NETIO230_isTimeMode($p[2]));
    return "$e_dFmt||'$p[3]'"   if (not NETIO230_isTimeFmtByType($p[3],$p[1]));  #on time
    return "$e_dFmt||'$p[4]'"   if (not NETIO230_isTimeFmtByType($p[4],$p[1]));  #off time
    return "$e_tPast||'$p[3]'"  if (    NETIO230_isTimeWarp($hash,$p[3],$p[1])); #on time
    return "$e_tPast||'$p[4]'"  if (    NETIO230_isTimeWarp($hash,$p[4],$p[1])); #off time
    return "$e_wFmt||'$p[5]'"   if (not(NETIO230_isWeekday($p[5])) && NETIO230_isWeekly($p[2]));
    return "$e_tma||'$p[5]'"    if (not(NETIO230_isWeekly($p[2])) && int(@p) > 5);
    return "$e_tma||'$p[6]'"    if (    NETIO230_isWeekly($p[2])  && int(@p) > 6);

  } elsif ($cmd eq "eth") {
    return undef                if (int(@p) == 1 && $p[0] eq "dhcp");
    if ($p[0] eq "manual") {
      return "$e_ip||'$p[1]'"   if (not NETIO230_isIPv4($p[1]));    #ip
      return "$e_nm||'$p[2]'"   if (not NETIO230_isNetmask($p[2])); #nm
      return "$e_ip||'$p[3]'"   if (not NETIO230_isIPv4($p[3]));    #gw
      return "$e_tma||'$p[4]'"  if (int(@p) > 4);
    } else {
      return "$e_dhcp||'$p[0]'"; }

  } elsif ($cmd eq "help") {
    return "$e_cmd||'$p[0]'"    if (not NETIO230_isKnownCmd($p[0])); }

  return undef; #everything is fine...
}


# ------------------------------------------------------------------------------
# --- helper functions: (syntaxCheck) ------------------------------------------
# ------------------------------------------------------------------------------

sub NETIO230_isWeekday($)     {return if(!defined $_[0]); return 1 if($_[0] =~ /^[01]{7}$/)}
sub NETIO230_isWeekly($)      {return if(!defined $_[0]); return 1 if($_[0] =~ /^weekly$/)}
sub NETIO230_isTimeType($)    {return if(!defined $_[0]); return 1 if($_[0] =~ /^(t|dt|ux)$/)}
sub NETIO230_isTimeMode($)    {return if(!defined $_[0]); return 1 if($_[0] =~ /^(once|daily|weekly)$/)}
sub NETIO230_isDisEnable($)   {return if(!defined $_[0]); return 1 if($_[0] =~ /^enable|disable$/)}
sub NETIO230_isBeginEnd($)    {return if(!defined $_[0]); return 1 if($_[0] =~ /^begin|end$/)}
sub NETIO230_is01($)          {return if(!defined $_[0]); return 1 if($_[0] =~ /^(0|1)$/)}
sub NETIO230_isOnOff($)       {return if(!defined $_[0]); return 1 if($_[0] =~ /^(on|off)$/)}
sub NETIO230_isInteger($)     {return if(!defined $_[0]); return 1 if($_[0] =~ /^\d+$/ && $_[0] <= 65535 && $_[0] >= 0 )}
sub NETIO230_isByte($)        {return if(!defined $_[0]); return 1 if($_[0] =~ /^\d+$/ && $_[0] <= 255 && $_[0] >= 0 )}
sub NETIO230_isManualTimer($) {return if(!defined $_[0]); return 1 if($_[0] =~ /^(manual|timer)$/)}
sub NETIO230_isSocketAlias($) {return if(!defined $_[0]); return 1 if($_[0] =~ /^\"[A-Za-z]+[A-Za-z0-9\s\._]*\"$/)}
sub NETIO230_isIPv4($)        {return if(!defined $_[0]); return 1 if($_[0] =~ /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/)}
sub NETIO230_isNetmask($)     {return if(!defined $_[0]); return 1 if($_[0] =~ /^(255|254|252|248|240|224|192|128)\.0\.0\.0|255\.(255|254|252|248|240|224|192|128|0)\.0\.0|255\.255\.(255|254|252|248|240|224|192|128|0)\.0|255\.255\.255\.(255|254|252|248|240|224|192|128|0)$/)}
sub NETIO230_isDateFmt($)     {return if(!defined $_[0]); return 1 if($_[0] =~ /^(19|20)\d\d\/(0[1-9]|1[012])\/(0[1-9]|[12][0-9]|3[01]),([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$/)}
sub NETIO230_isTimeTFmt($)    {return if(!defined $_[0]); return 1 if($_[0] =~ /^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$/)}
sub NETIO230_isTimeUxFmt($)   {return if(!defined $_[0]); return 1 if($_[0] =~ /^[0]*[x]*[a-f0-9]{8}$/)}
sub NETIO230_isTimezone($)    {return if(!defined $_[0]); return 1 if($_[0] =~ /^UTC[+-]*(\d|1[1-2])*$/)}

# ------------------------------------------------------------------------------
sub NETIO230_isMinMaxSI($$$) {
  my ($val,$min,$max) = @_;
  return if (!defined $val);
  if ($val =~ /^([\d]*[\.]?+\d+)(s|m|h)*$/)
  {
    $val = $1;
    $val = $val+1-1; # 0.1 will be a string otherwise
    $val *= 10 if ($2 eq "s");
    $val *= 600 if ($2 eq "m");
    $val *= 36000 if ($2 eq "h");
    return $val if ($val >= $min && $val <= $max);
  }
}

# ------------------------------------------------------------------------------
sub NETIO230_isSocketDefined($$) {
  my ($hash,$socket) = @_;
  return if (!defined $socket);
  my @sockets = @{$hash->{SOCKETS}};
  my $allowedSockets = join("",@sockets);
  return 1 if ($allowedSockets =~ /$socket/ && length($socket) == 1);
}

# ------------------------------------------------------------------------------
sub NETIO230_isSocketNameDefined($$) {
  my ($hash,$socket) = @_;
  return 1 if (defined $hash->{helper}{aliases}{$socket}); #socket alias name
  return 1 if (NETIO230_isSocketDefined($hash,$socket))
}

# ------------------------------------------------------------------------------
sub NETIO230_isFqdnIP($) {
  return if (!defined $_[0]);
  return 1 if ($_[0] =~ /^(?=^.{4,253}$)(^((?!-)[a-zA-Z0-9-]{1,63}(?<!-)\.)+[a-zA-Z]{2,63}$)$/
  || $_[0] =~ /^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/)
}

# ------------------------------------------------------------------------------
sub NETIO230_isKnownCmd($) {
  return if (!defined $_[0]);
  my $cmdsAvail = " ".join(" ", keys %NETIO230_setCmds)." ";
  return 1 if ($cmdsAvail =~ /\s$_[0]\s/ );
}

# ------------------------------------------------------------------------------
sub NETIO230_isTimeFmtByType($$) {
  my ($time,$ts) = @_;
  return if (!defined $time);
  return 1 if ($ts eq "t"  && (NETIO230_isTimeTFmt($time)));
  return 1 if ($ts eq "dt" && (NETIO230_isDateFmt($time)));
  return 1 if ($ts eq "ux" && (NETIO230_isTimeUxFmt($time)));
}

# ------------------------------------------------------------------------------
sub NETIO230_isTimeWarp($$$) {
  my ($hash,$time,$ts) = @_;
  if ($ts eq "t") {  # HH:MM:SS
    my ($dnow,$tnow) = split(" ",TimeNow());
    return 1 if (NETIO230_getTimeDiv($hash,"$dnow $time") < 0);
  }
  if ($ts eq "dt") { # YYYY/MM/DD,HH:MM:SS
    return 1 if (NETIO230_getTimeDiv($hash,NETIO230_netioToFhemTimeFmt($time)) < 0);
  }
  if ($ts eq "ux") {
    # to be done   # (0|0x)*xxxxxxxx
  }
}


# ------------------------------------------------------------------------------
# --- time helper functions: ---------------------------------------------------
# ------------------------------------------------------------------------------

sub NETIO230_checkTimeDiff($)
{
  my ($hash) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  my $d = NETIO230_getTimeDiv($hash);

  if (abs($d) < 120) {
    my $genEvent = 1;
    $genEvent = 0 if (defined $hash->{READINGS}{timediff}{VAL} && $hash->{READINGS}{timediff}{VAL} < 120);
    readingsSingleUpdate($hash,"timediff",$d,$genEvent);
  }
  elsif (abs($d) > 120) {
    NETIO230_log($name,"time diff >2 min: $d sec","NOTICE: ");
    readingsSingleUpdate($hash,"timediff",$d,1);
  }
  elsif (abs($d) > 1800) {
    NETIO230_log($name,"time diff >30 min: $d sec","ERROR: ");
    readingsSingleUpdate($hash,"timediff",$d,1);
  }

  return undef;
}

# ------------------------------------------------------------------------------
sub NETIO230_getTimeDiv($;$) #check timenow() against time reading (or opt: value)
{
  my ($hash,$timeToCheck) = @_;
  my $name = $hash->{NAME};
  my $tDev = time_str2num(NETIO230_netioToFhemTimeFmt($hash->{READINGS}{time}{VAL}));
  $tDev = time_str2num($timeToCheck) if (defined $timeToCheck);
  my $tLoc = time_str2num(TimeNow());
  return $tDev - $tLoc;
}

# ------------------------------------------------------------------------------
sub NETIO230_netioToFhemTimeFmt($)
{
  my ($time) = @_;
  $time =~ s/,/ /;
  $time =~ s/\//-/g;
  return $time;
}


# ------------------------------------------------------------------------------
# --- more helper functions: ---------------------------------------------------
# ------------------------------------------------------------------------------

sub NETIO230_getSocketAlias($)
{
  my ($hash) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  my @sockets = @{$hash->{SOCKETS}};
  delete $hash->{helper}{aliases};
  foreach my $sock (@sockets) {
    if (defined $hash->{READINGS}{"socket$sock"."_setup"}{VAL}) {
      $hash->{READINGS}{"socket$sock"."_setup"}{VAL} =~ /"([a-zA-Z0-9\.\s_-]+)".*/;
      if (not $1 =~ / /) {
        $hash->{helper}{aliases}{$1} = $sock;
        $hash->{"SOCKET_ALIAS$sock"} = $1;
        #regiester as set cmd via http request, $name is needed because hash is global
        #$NETIO230_setCmds{"socket_$1"} = "http,$name,$1";
      }
    }
  }

  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_isPmInstalled($$)
{
  my ($hash,$pm) = @_;
  my $name = $hash->{NAME};
  if (not eval "use $pm;1")
  {
    NETIO230_log($name,"perl mudul missing: $pm");
    $hash->{MISSING_MODULES} .= "$pm ";
    return "failed: $pm";
  }
  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_md5token($$)
{
  my ($hash, $i) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());

  my $md5 = Digest::MD5->new;
  $md5->add($hash->{USER}, $hash->{PASS}, $i);
  $md5 = $md5->hexdigest;

  Log3 $name, 5, "$name: $self() <\"$i\" >\"$md5\"";
  return $md5;
}


# ------------------------------------------------------------------------------
sub NETIO230_stripHtml($)
{
  my ($data) = @_;
  $data =~ s/<(?:[^>'"]*|(['"]).*?\1)*>//gs; # html
  $data =~ s/^\s+//; # whitespace
  $data =~ s/\s+$//; # whitespace
  $data =~ s/\n//; # new line
  return $data;
}


# ------------------------------------------------------------------------------
sub NETIO230_delReadings($$;$)
{
  my ($hash,$type,$silent) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
#  $silent = "" if (not defined $silent);

  if ($type =~ /(http|all)/ ){
    my @sockets = @{$hash->{SOCKETS}};
    foreach my $num (@sockets) {
        delete $hash->{READINGS}{"socket$num"};
     }
    delete $hash->{READINGS}{state};
  }

  if ($type =~ /(telnet|all)/ ){
    my %sysCmds = NETIO230_sysCmds($hash);
    my @cList = sort values %sysCmds;
    foreach my $readings (@cList) {
      delete $hash->{READINGS}{$readings}
    }
  delete $hash->{READINGS}{"timediff"}
  }

  NETIO230_log($name,"readings wiped out ($type)") if (not defined $silent);
  return undef;
}


# ------------------------------------------------------------------------------
sub NETIO230_modifyReadings($$$)
{
  my ($hash,$reading,$val) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  my ($m,$s) = 0;
  my $orgVal = $val;

  if ($reading eq "socket") {
    $val =~ s/1/on/;
    $val =~ s/0/off/;

  } elsif ($reading eq "timezone")
    { if (int($val) >= 0) {
      $val = "UTC+".$val/3600;
    } elsif (int($val) < 0) {
      $val = "UTC".$val/3600; }

  } elsif ($reading eq "swdelay")

    { if ($val < 10) {
      $val *= 100;
      $val .="ms";

    } elsif ($val < 600) {
      $val /= 10;
      $val .= "s";

    } elsif ($val >= 600) {
      $val /= 10; #now in sec
      $m = int($val/60);
      $s = $val - $m*60;
      $s = int($s +0.5); #quick round that do not display 59m 60s for 1h
      $val = $m."min ".$s."sec";

    } if ($m >= 60) {
      $m -= 60;
      $val = "1h ".$m."min ".$s."sec";
    }}

  Log3 $name, 5, "$name: $self() reading:'$reading' orgVal:'$orgVal' newVal:'$val'";
  return $val;
}


# ------------------------------------------------------------------------------
sub NETIO230_modifyUserInput($$$)
{
  my ($hash,$cmd,$val) = @_;
  my ($name,$self) = ($hash->{NAME},NETIO230_whoami());
  $val = "" if (!defined $val);
  my $orgVal = $val;

  if ($cmd eq "timezone") {
    $val =~ s/UTC//;
    $val = $val * 3600;
  }

#  elsif ($cmd eq "swdelay" && $val =~ /^(\d+)(s|m|h)$/) {
#  elsif ($cmd eq "swdelay" && $val =~ /^([\d]*[\.]*\d+)(s|m|h)$/) {
  elsif ($cmd eq "swdelay" && $val =~ /^([\d]*[\.]?+\d+)(s|m|h)$/) {
    $val = int(NETIO230_isMinMaxSI($val,"0","65535"));
  }

  Log3 $name, 5, "$name: $self() cmd:'$cmd' orgVal:'$orgVal' newVal:'$val'";
  return $val;
}


# ------------------------------------------------------------------------------
sub NETIO230_whoami()  { return (split('::',(caller(1))[3]))[1] || ''; }


# ------------------------------------------------------------------------------
sub NETIO230_log($$;$)
{
  my ($name,$log,$errText) =  @_;
  my $hash = $defs{$name};
  my $logmsg = NETIO230_stripHtml($log);
  my $txtmsg = "";
  my $genEvent = "1";  # generate Events on default
  my $isStatus = "0";  # mark system errors
  my $ll = 2;          # default verbose level

  $errText = "ERROR: " if (not defined $errText);

# --- Informational logs..
  if ($log =~ /^get $name/) {
    $ll = 4;
    $isStatus = "1";
    $genEvent = "0";
    $errText = "";

  } elsif ($log =~ /^set $name (on|off): failed/) {
    $ll = 2;
    $isStatus = "1";
    $genEvent = "1";

  } elsif ($log =~ /^set $name statusRequest/) {
    $ll = 4;
    $isStatus = "1";
    $genEvent = "0";
    $errText = "";

  } if ($log =~ /^set $name system.dns (.*)/) {
    $ll = 3;
    $isStatus = "0";
    $genEvent = "1";
    $errText = "NOTICE: ";
    $txtmsg = "=> You have to reboot your PDU to activate ".
              "new dns server settings.";

  } elsif ($log =~ /^set $name/) {
    $ll = 3;
    $isStatus = "1";
    $genEvent = "1";
    $errText = "";

  } elsif ($log =~ /^request pwdhash$/) {
    $ll = 4;
    $isStatus = "0";
    $genEvent = "0";
    $errText = "NOTICE: ";
    $txtmsg = "=> Request new password hash from device.";

  } elsif ($log =~ /^got pwdhash$/) {
    $ll = 4;
    $isStatus = "0";
    $genEvent = "0";
    $errText = "NOTICE: ";
    $txtmsg = "=> Login with new token.";

  } elsif ($log =~ /502 UNKNOWN COMMAND/) {
    $ll = 4; # Unknown commands are only logged once, ll 4 should be enough
    $errText = "NOTICE: ";
    $txtmsg = "=> Specified command isn\'t supported by device type or ".
              "firmware version. Check for an update, please.";

  # --- soft errors
  } elsif ($log =~ /^retry timed out/) {
    $ll = 4;
    $errText = "NOTICE: ";
    $txtmsg = "=> Device is busy or unavailable. Retrying...";

  } elsif ($log =~ /553 retry login/) {
    $ll = 4;
    $errText = "NOTICE: ";
    $txtmsg = "=> Secure login failed. Awaiting new token...";

  } elsif ($log =~ /^alternate HTTP URL/ ) {
    $ll = 4;
    $txtmsg = "=> Using alternate URL.";
    $errText = "NOTICE: ";

  } elsif ($log =~ /^alternate HTTP CMD/ ) {
    $ll = 4;
    $txtmsg = "=> Using alternate commands for http requests (login/list/port).";
    $errText = "NOTICE: ";

  } elsif ($log =~ /(offline: )(.*)/) {
    $ll = 3;
    $errText = "NOTICE: ";
    $txtmsg = "=> Device is marked to be offline. Nevertheless trying to executing: \"$2\"";

  # --- return from error
  } elsif ($log =~ /^OK: http$/) {
    $ll = 3;
    $errText = "NOTICE: ";
    $txtmsg = "=> Http connection is working again.";

  } elsif ($log =~ /^OK: telnet$/) {
    $ll = 3;
    $errText = "NOTICE: ";
    $txtmsg = "=> Telnet connection is working again.";

  # --- firmware version dependency
  } elsif ($log =~ /501 INVALID PARAMETR/) {
    $txtmsg = "=> Specified parameter isn\'t supported by device type or ".
              "firmware version.";
    $ll = 3;
    $errText = "NOTICE: ";

  # --- Attributes
  } elsif ($log =~ /^attr ([a-z-A-Z0-9_-]+) ([a-z-A-Z0-9_-]+) != (.*)/ ) {
    $txtmsg = "=> \"$2\" cannot be used as value for attribut $1. Value has ".
              "to be: $3";

  } elsif ($log =~ /^attr $name/ ) {
    $ll = 4;
    $errText = "";
    $isStatus = "1";
    $genEvent = "0";

  # --- as a consequence of an error
  } elsif ($log =~ /^readings wiped out/) {
    $ll = 4;
    $genEvent = "0";
    $errText = "NOTICE: ";
    $txtmsg = "=> all readings with unknown state were wiped out.";

  # --- hard errors
  } elsif ($log =~ /^Wrong syntax/) {
    $isStatus = "1";

  } elsif ($log =~ /^perl modul missing: (.*)/ ) {
    $errText = "NOTICE: ";
    $txtmsg = "=> Perl modul $1 is not installed, reduced ".
              "functionality. Please install perl module $1 and restart FHEM.";

  } elsif ($log =~ /^failed: no telnet prompt/) {
    $txtmsg = "=> Telnet connect failed. Please turn on your device, ".
              "check for network, correct host address and telnet port.";

  } elsif ($log =~ /No route to host/ ||
         $log =~ /connect to .* timed out/) {
    $txtmsg = "=> Http connect failed. Please turn on your device, ".
              "check for network or correct host address.";

  } elsif ($log =~ /Connection refused/) {
    $txtmsg = "=> Cannot open device. Port is closed. Check for correct host".
              " address.";

  } elsif ($log =~ /120 Rebooting/) {
    $txtmsg = "=> PDU will a be available in a few seconds again.";

  } elsif ($log =~ /500 INVALID VALUE/) {
    $txtmsg = "=> Specified parameter in incorrect. See command reference for ".
              "details.";

  } elsif ($log =~ /503 INVALID LOGIN/) {
    $txtmsg = "=> Telnet login failed. Wrong Credentials?";

  } elsif ($log =~ /5\d5 FORBIDDEN/) {
    $txtmsg = "=> You are not allowed to modify system parameters. ".
              "Browse to http://".$hash->{HOST}." and check that user \"".
              $hash->{USER}."\" has sufficient rights or choose another user ".
              "in your definition for $name";

  } elsif ($log =~ /551 INVALID PARAMETR/) {
    $txtmsg = "=> Http command failed. Get in contact with support ".
              "(http://forum.fhem.de/index.php/topic,47814).";

  } elsif ($log =~ /553 INVALID LOGIN/) {
    $txtmsg = "=> Http login failed. Wrong Credentials or simultaneously ".
    "secure logins from multiple clients.";

  } elsif ($log =~ /empty answer received/) {
    $txtmsg = "=> Http URL wrong: Get in contact with support ".
              "(http://forum.fhem.de/index.php/topic,47814).";

  } elsif ($log =~ /^failed: BlockingCall/) {
    $txtmsg = "=> A background mechanism did not work as expected. If this ".
              "error occurs regularly: Set attribute disable_fork = 1";

  } if ($logmsg =~ /^(Wrong syntax: '.*').*('.*')$/) {
    readingsSingleUpdate($hash,"_lastNotice","$1 =>$2",1) if ($genEvent eq "1");
  } else {
    readingsSingleUpdate($hash,"_lastNotice",$logmsg,1) if ($genEvent eq "1"); }

  $logmsg = "[".$logmsg."]" if (!$isStatus);
  Log3 $name, $ll, "$name: $errText$logmsg $txtmsg";

  return $logmsg;
}



=pod
=item device
=begin html

<a name="NETIO230"></a>
<h3>NETIO230</h3>
<ul>
  <p>
    Provides access and control to NETIO-230 (A/B/C models) Power Distribution
    Unit (see:
    <a href="http://www.koukaam.se/kkmd/showproduct.php?article_id=1504">
    NETIO-230A</a> /
    <a href="http://www.netio-products.com/en/product/netio-230b/">
    NETIO-230B</a> /
    <a href="http://www.netio-products.com/en/product/netio-230c/">
    NETIO-230C</a> on koukaam.se)
  </p>

  <b>Notes</b>
  <ul>
    <li>Requirements: perl modules <b>Net::Telnet</b> and <b>Digest::MD5</b>
      lately. There is reduced functionality if they are not installed, but it
      will work with basic functions. 1(!) notice will be logged if modules are
      not installed while loading the modul.
      </li><br>
    <li>If you are going to use multiple instances of this module with the same
      physical device and using secure login then all instances have to use the
      same username.
      </li><br>
  </ul>
  <br>

  <a name="NETIO230define"></a>
  <b>Define</b>
  <ul>

    <code>define &lt;name&gt; NETIO230 &lt;ip_address&gt; 
    [s:&lt;socket(s)&gt;] [i:&lt;interval&gt;] [h:&lt;http_port&gt;]
    [t:&lt;telnet_port(s)&gt;] [u:&lt;username&gt;] [p:&lt;password&gt;]
    </code><br>

  <p><u>Mandatory:</u></p>
  <ul>
  <code>&lt;name&gt;</code>
  <ul>Specifies a device name of your choise.<br>
  eg. <code>myNetio</code>
  </ul>
  <code>&lt;ip_address&gt;</code>
  <ul>Specifies device IP address.<br>
  eg. <code>172.16.4.100</code>
  </ul>
  </ul>

  <p><u>Optional</u> (in any order):</p>
  <ul>
  <code>s:&lt;socket(s)&gt;</code>
  <ul>Specifies your sockets to be used with this device. Default: all ports<br>
  eg. s:1, s:23, s:134 or s:4321
  </ul>

  <code>h:&lt;http_port&gt;</code>
  <ul>Http port to be used. Default: 80
  </ul>

  <code>t:&lt;telnet_port&gt;</code>
  <ul>Telnet port to be used. Default: 1234
  </ul>

  <code>i:&lt;interval&gt;</code>
  <ul>Interval in seconds for device polling (statusRequest). Default: 300
  </ul>

  <code>u:&lt;username&gt;</code>
  <ul>Is a username for http and telnet login. Default: admin
  </ul>

  <code>p:&lt;passsword&gt;</code>
  <ul>Matching password for &lt;username&gt;. Default: admin
  </ul>
  </ul>

    <p><u>Define Examples:</u></p>
    <ul>
      <li><code>define MyNetio NETIO230 172.16.4.100</code></li>
      <li><code>define Socket3 NETIO230 172.16.4.100 s:3</code></li>
      <li><code>define Socket3_4 NETIO230 172.16.4.100 s:34 i:3600 h:80 t:1234
        u:admin p:admin</code></li>
    </ul>
  </ul>
<br>
  <a name="NETIO230get"></a>
  <b>Get </b>
  <ul>
    <li>alias<br>
      returns the system name of device.<br>
      possible value: <code>&lt;string&gt;</code><br>
      </li><br>
    <li>discover<br>
      returns whether the device can be discovered by Netio's config software.
      <br>
      possible values: <code>&lt;enable|disable&gt;</code><br>
      </li><br>
    <li>dns<br>
      returns current dns server.<br>
      possible value: <code>&lt;ip address&gt;</code><br>
      </li><br>
    <li>dst<br>
      returns daylight saving time settings.<br>
      possible values: <code>&lt;enable|disable&gt; &lt;dst_start&gt;
      &lt;dst_end&gt;</code><br>
      eg. <code>enabled 2010/01/08,10:21:20 - 2010/10/31,03:00:00</code><br>
      </li><br>
    <li>eth<br>
      returns ipv4 network settings.<br>
      possible values: <code>&lt;dhcp|manual&gt; [&lt;ip_address&gt;
      &lt;mask&gt; &lt;gateway&gt;]</code><br>
      </li><br>
    <li>ntp<br>
      returns sntp settings.<br>
      possible values: <code>&lt;enable|disable&gt; &lt;ip|hostname&gt;
      [synchronized]</code><br>
      </li><br>
    <li>presence<br>
      returns presence of device.<br>
      possible values: <code>&lt;present|absent&gt;</code><br>
      </li><br>
    <li>smtp<br>
      returns ip address or domain name of the SMTP server.<br>
      possible values: <code>&lt;ip|fqdn&gt;</code><br>
      </li><br>
    <li>state<br>
      returns the state of the socket(s). state will be on unless ALL ports are
      off. Use stateFormat if you need another option.<br>
      passible values: <code>&lt;on|off&gt;</code><br>
      </li><br>
    <li>socketX<br>
      returns state of socketX<br>
      X is number from 1-4 which represents the socket number.<br>
      possible values: <code>&lt;on|off&gt;</code><br>
      </li><br>
    <li>socketX_setup<br>
      returns setup of socketX<br>
      X is number from 1-4 which represents the socket number.<br>
      possible values: <code>&lt;output_name&gt; &lt;mod: manual|timer&gt;
      &lt;interrupt_delay&gt; &lt;power_on_status&gt;</code><br>
      </li><br>
    <li>socketX_timer<br>
      returns timer for socketX<br>
      X is number from 1-4 which represents the socket number.<br>
      possible values: <code>&lt;mode: once|daily|weekly&gt; &lt;on-time&gt;
      &lt;off-time&gt; &lt;week_schedule: 1111100&gt;</code><br>
      </li><br>
    <li>socketX_wd<br>
      returns watchdog settings for socketX, where X is a defined socket number.
      <br>
      possible values: <code>&lt;enable|disable&gt; &lt;ip_address&gt;
      &lt;timeout&gt; &lt;pon_delay&gt; &lt;ping_refresh&gt; &lt;max_retry&gt;
      &lt;<i><small>max_retry_poff:</small></i>enable|disable&gt;
      &lt;<i><small>email:</small></i>enable|disable&gt;</code><br>
      </li><br>
    <li>swdelay<br>
      returns delay between triggering two outputs.<br>
      possible value: <code>&lt;time in ms,s,m,h&gt;</code><br>
      </li><br>
    <li>time<br>
      returns current local system time<br>
      possible value: <code>YYYY/MM/DD,HH:MM:SS</code><br>
      </li><br>
    <li>timediff<br>
      returns time dissension between Netio PDU and FHEM. A notice will be
      logged if there is a difference of more than 120 sec. An error will be
      logged if difference is greater than half an hour. Use ntp server and
      check dst settings if there are inconsistencies.<br>
      possible value: <code>seconds</code><br>
      </li><br>
    <li>timezone<br>
      returns current local time zone.<br>
      possible value: <code>from &lt;UTC-12&gt; till &lt;UTC+14&gt;</code>
      <br>
      </li><br>
    <li>uptime<br>
      returns current NETIOs uptime<br>
      possible value: <code>&lt;X years X days X hours X min X sec&gt;</code>
      <br>
      </li><br>
    <li>_lastNotice<br>
      returns system notice or http/telnet error code received from device.<br>
      <br>
      </li><br>
  </ul>
<br>
  <a name="NETIO230set"></a>
  <b>Set </b>
  <ul>
    <li>alias<br>
      Set device alias name.<br>
      required parameter: string (use quote marks if name contains a space)<br>
      eg. <code>set myNetio alias newName</code>
      </li><br>
    <li>discover<br>
      Enables / disables visibility of the device for the network Discover
      utility.<br>
      required parameter: &lt;enable|disable&gt;<br>
      eg. <code>set myNetio discover enable</code>
      </li><br>
    <li>dns<br>
      Sets IP address of the DNS server. To allow changed values to take effect
      you must restart the device.<br>
      required parameter: &lt;ip_address&gt;<br>
      eg. <code>set myNetio dns 8.8.8.8</code>
      </li><br>
    <li>dst<br>
      Sets dayligh saving time.<br>
      required parameter: &lt;enable|disable|begin|end&gt;
      [&lt;YYYY/MM/DD,hh:mm:ss&gt;]<br>
      eg. <code>set myNetio dst enable</code><br>
      eg. <code>set myNetio dst disable</code><br>
      eg. <code>set myNetio dst begin 2016/03/27,02:00:00</code><br>
      eg. <code>set myNetio dst end 2016/10/30,03:00:00</code>
      </li><br>
    <li>eth<br>
      Setup of the network interface parameters: IP address, subnet mask and
      gateway parameters are needed to pass only if manual mode is entered.
      To allow changed values to take effect you must restart the device.<br>
      required parameter: &lt;dhcp|manual&gt; [&lt;ip_address&gt; &lt;mask&gt;
      &lt;gateway&gt;]<br>
      eg. <code>set myNetio net manual 172.16.4.150 255.255.252.0
      192.168.10.1</code>
      </li><br>
    <li>help<br>
      Show set command usage and notes.<br>
      required parameter: &lt;set cmd&gt;<br>
      eg. <code>set myNetio help timer</code>
      </li><br>
    <li>ntp<br>
      SNTP client settings, enables or disables time synchronization with SNTP
      server. Server address can be entered both as IP address or domain name.
      <br>
      required parameter: &lt;sntp ip|fqdn&gt;<br>
      eg. <code>set myNetio time_ntp ptbtime1.ptb.de</code>
      </li><br>
    <li>on<br>
      Switch all assigned sockets on.<br>
      eg. <code>set myNetio on</code>
      </li><br>
    <li>off<br>
      Switch all assigned sockets off.<br>
      eg. <code>set myNetio off</code>
      </li><br>
    <li>port<br>
      Alias command for <a href="#NETIO230set_socket">socket</a>
      </li><br>
    <li>reboot<br>
      Restarts PDU.<br>
      required parameter: n/a<br>
      eg. <code>set myNetio reboot</code>
      </li><br>
    <li>setup<br>
      Setup socket parameters like name, manual/timer control, interruption
      interval and power on state. Name must be enclosed in quotation marks.<br>
      possible parameters: &lt;socket_num|socket_alias&gt; &lt;output_name&gt;
      &lt;mod: manual|timer&gt; &lt;interrupt_delay&gt; &lt;pon_status&gt;<br>
      eg. <code>set MyNetio setup 1 "output_1“ manual 2 1</code><br>
      Will set socket1 name output_1, enable manual control, interruption
      interval to 2 seconds and power on state to on<br>
      </li><br>
    <li>smtp<br>
      Sets IP address or domain name of the SMTP server.<br>
      required parameter: &lt;ip|fqdn&gt;<br>
      eg. <code>set myNetio smtp mail.guerrillamail.com</code>
      </li><br>
  <a name="NETIO230set_socket"></a>
    <li>socket<br>
      Each single socket can also be switched on or off instead of all sockets
      together. See 'set setup' for how to setup socket_alias names.<br>
      required parameters: &lt;socket_number|socket_alias&gt; &lt;on|off&gt;<br>
      eg. <code>set myNetio socket 1 on</code><br>
      eg. <code>set myNetio socket socket_1 off</code>
      </li><br>
    <li>statusRequest<br>
      Polls the PDU for current state and settings. Periodical updates can be
      configured with intervalPresent and intervalAbsent attributes. Default:
      every 5min. See attribute section below.<br>
      eg. <code>set myNetio statusRequest</code>
      </li><br>
    <li>swdelay<br>
      Sets delay between triggering two outputs. Unit is 1/10s without suffix.
      Possible suffixes are: s,m<br>
      required parameter: &lt;number[s|m]&gt; (max: 65535 (~109m/6553s))<br>
      eg. <code>set myNetio swdelay 2</code><br>
      eg. <code>set myNetio swdelay 3s</code><br>
      eg. <code>set myNetio swdelay 2m</code>
      </li><br>
    <li>time<br>
      Sets local system time.<br>
      required parameter: &lt;YYYY/MM/DD,HH:MM:SS&gt;<br>
      eg. <code>set myNetio time 2015/01/12,15:00:00</code>
      </li><br>
    <li>timer<br>
      Sets a hardware timer for a socket. Times in the past will not be
      accepted. Reading timediff will not be taken into consideration.
      See 'set setup' for how to setup socket_alias names.<br>
      required parameter: &lt;socket_num|socket_alias&gt; &lt;time_format:
      t|dt|ux&gt; &lt;mode: once|daily|weekly&gt; &lt;on-time&gt;
      &lt;off-time&gt; [&lt;week_schedule&gt;]<br>
      Where &lt;time_format&gt; is:<br>
      <code>
      t: &nbsp;HH:MM:SS<br>
      dt: YYYY/MM/DD,HH:MM:SS<br>
      ux: xxxxxxxx (unsigned long with prefix 0x<hex>, 0<octal> or decimal)
      </code><br>
      eg. <code>set myNetio timer mySock3 weekly 10:00:00 11:30:00 1111100
      </code><br>
      eg. <code>set myNetio timer 3 weekly 10:00:00 11:30:00 1111100</code><br>
      Switches the timer on at socket 3. From Monday to Friday, socket 3 will
      always be switched on at 10:00 and switched off at 11:30.
      </li><br>
    <li>timezone<br>
      Sets local time zone. UTC syntax has to be used.<br>
      required parameter: from <code>&lt;UTC-12&gt;</code> till 
      <code>&lt;UTC+14&gt;</code><br>
      eg. <code>set myNetio timezone UTC+1</code>
      </li><br>
    <li>watchdog<br>
      Used to set a watchdog per socket.<br>
      required parameters: &lt;socket_num|socket_alias&gt;
      &lt;enable|disable&gt; &lt;ip_address&gt; &lt;timeout&gt;
      &lt;pon_delay&gt; &lt;ping_refresh&gt; &lt;max_retry&gt;
      &lt;<i><small>max_retry_poff:</small></i>enable|disable&gt;
      &lt;<i><small>email:</small></i>enable|disable&gt;<br>
      eg. <code>set myNetio watchdog 2 enable 192.168.10.101 10 30 1 3 enable
      enable</code><br>
      eg. <code>set myNetio watchdog mySock2 enable 192.168.10.101 10 30 1 3
      enable enable</code><br>
      Will enable the Watchdog feature on output 2. Device on address
      192.168.10.101 will be monitored, max Ping response time 10 seconds.
      Ping commands will be sent in 1 second intervals. If the monitored device
      won't respond in 10 seconds, output 2 will be turned OFF for 30 seconds.
      If the device will fail to respond to Ping commands after the third
      restart the output will stay OFF. You will be notified by warning e-mail
      after each reset of the output.
      </li><br>
    <li><a href="#setExtensions">setExtensions</a><br>
  <ul>
   <li>on-for-timer &lt;seconds&gt;</li>
   <li>on-till &lt;timedet&gt</li>
   <li>on-till-overnight &lt;timedet&gt</li>
   <li>off-for-timer &lt;seconds&gt</li>
   <li>off-till &lt;timedet&gt</li>
   <li>off-till-overnight &lt;timedet&gt</li>
   <li>blink &lt;number&gt; &lt;blink-period&gt;</li>
   <li>intervals &lt;from1&gt;-&lt;till1&gt; &lt;from2&gt;-&lt;till
       2&gt;...</li><br>
   </ul>
    </li>
  </ul>
<br>
 <a name="NETIO230attr"></a>
  <b>Attributes</b>
  <ul>
    <li>disable<br>
      Used to disable device polling and set commands.<br>
      Possible values: 0,1<br>
      </li><br>
    <li>disable_fork<br>
      Used to switch off the so called forking for non-blocking functionality,
      in this case for telnet queries. It is not recommended to use this
      attribute but some operating systems seem to have a problem due to
      forking a FHEM process (Windows?). Http requests are not affected by this
      attribute. Http communication will work non-blocking with this module
      version in all cases.<br>
      Possible values: <code>0,1</code><br>
      </li><br>
    <li>disable_telnet<br>
      Disable the use of telnet at all.<br>
      Possible values: <code>0,1</code><br>
      </li><br>
    <li>enable_timeEvents<br>
      Enable events for readings 'time' and 'uptime'.<br>
      Possible values: <code>0,1</code><br>
      </li><br>
    <li>intervalPresent<br>
      Used to set device polling interval in seconds when device is present.<br>
      Possible value: <code>integer &gt;= 30</code><br>
      </li><br>
    <li>intervalAbsent<br>
      Used to set device polling interval in seconds when device is absent.<br>
      Possible value: <code> integer &gt;= 30</code><br>
      </li><br>
    <li>secureLogin<br>
      A md5 hash will be used instead of a plain text password. Perl modul
      Digest::MD5 must be installed to be able use this feature.<br>
      Possible value: <code>0,1</code><br>
      </li><br>
    <li><a href="#readingFnAttributes">readingFnAttributes</a><br>
      Attributes like event-on-change-reading, event-on-update-reading,
      event-min-interval, event-aggregator, stateFormat, userReadings, ...
      are working, too.
      </li><br>
  </ul>
</ul>

=end html

=cut

1;
