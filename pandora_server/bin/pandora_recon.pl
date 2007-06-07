#!/usr/bin/perl
##########################################################################
# Pandora FMS Recon Server
##########################################################################
# Copyright (c) 2007 Sancho Lerena, slerena@gmail.com
# Copyright (c) 2007 Artica Soluciones Tecnologicas S.L
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 2
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
##########################################################################

# Includes list
use strict;
use warnings;

use Date::Manip;        # Needed to manipulate DateTime formats
						# of input, output and compare
use Time::Local;        # DateTime basic manipulation
use NetAddr::IP;		# To manage IP Addresses
use POSIX;				# to use ceil() function
use Socket;				# to resolve address
use threads;

# Pandora Modules
use PandoraFMS::Config;
use PandoraFMS::Tools;
use PandoraFMS::DB;
use PandoraFMS::PingExternal;

# FLUSH in each IO (only for debug, very slooow)
# ENABLED in DEBUGMODE
# DISABLE FOR PRODUCTION
$| = 1;

my %pa_config;

# Inicio del bucle principal de programa
pandora_init(\%pa_config, "Pandora FMS Recon server");
# Read config file for Global variables
pandora_loadconfig (\%pa_config, 3);
# Audit server starting
pandora_audit (\%pa_config, "Pandora FMS Recon Daemon starting", "SYSTEM", "System");
sleep(1);

# Connect ONCE to Database, we cannot pass DBI handler to all subprocess because
# cannot share DBI between threads without use method CLONE.
my $pa_config = \%pa_config;
my $dbhost = $pa_config->{'dbhost'};
my $dbuser = $pa_config->{'dbuser'};
my $dbpass = $pa_config->{'dbpass'};
my $dbname = $pa_config->{'dbname'};
my $dbh = DBI->connect("DBI:mysql:$dbname:$dbhost:3306", $dbuser, $dbpass, { RaiseError => 1, AutoCommit => 1 });

# Daemonize of configured
if ( $pa_config{"daemon"} eq "1" ) {
	print " [*] Backgrounding...\n";
	&daemonize;
}

# Runs main program (have a infinite loop inside)

threads->new( \&pandora_recon_subsystem, \%pa_config);
sleep(1);

while ( 1 ){
	pandora_serverkeepaliver ($pa_config, 3, $dbh);
	threads->yield;
	sleep($pa_config->{"server_threshold"});
}

#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------
#---------------------  Main Perl Code below this line-----------------------
#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------

##########################################################################
# SUB pandora_recon_subsystem
# This module runs each X seconds (server threshold) checking for new
# recon tasks pending to do
##########################################################################

sub pandora_recon_subsystem {
        # Init vars
	my $pa_config = $_[0];
	my $dbh = DBI->connect("DBI:mysql:$pa_config->{'dbname'}:$pa_config->{'dbhost'}:3306", $pa_config->{'dbuser'}, $pa_config->{'dbpass'}, { RaiseError => 1, AutoCommit => 1 });
	my $server_id = dame_server_id($pa_config, $pa_config->{'servername'}."_Recon", $dbh);
	my $query_sql; 			# for use in SQL
	my $exec_sql; 			# for use in SQL
	my @sql_data;			# for use in SQL 
	while ( 1 ) {
		logger ($pa_config, "Loop in Recon Module Subsystem", 10);
		$query_sql = "SELECT * FROM trecon_task WHERE id_network_server = $server_id AND status = -1";
		$exec_sql = $dbh->prepare($query_sql);
		$exec_sql ->execute;
		while (@sql_data = $exec_sql->fetchrow_array()) {
			my $interval = $sql_data[11];
			my $my_timestamp = &UnixDate("today","%Y-%m-%d %H:%M:%S");
			my $my_utimestamp = &UnixDate($my_timestamp, "%s"); # convert from human to integer
			my $utimestamp = $sql_data[9];
    			my $id_task = $sql_data[0];
    			my $task_name = $sql_data[1];
			# Need to exec this task ?
			if (($utimestamp + $interval) < $my_utimestamp){
				logger($pa_config,"Recon Server: Executing task [$task_name]",8);
   				# EXEC TASK and mark as "in progress" != -1
   				pandora_update_reconstatus ($pa_config, $dbh, $id_task, 0);
   				threads->new( \&pandora_exec_task, $pa_config, $id_task);
				# pandora_exec_task ($pa_config, $id_task);
			}
      		}
      		$exec_sql->finish();
		sleep($pa_config->{"server_threshold"});
	}
}

##########################################################################
# SUB pandora_exec_task (pa_config, id_task)
# Execute task
##########################################################################
sub pandora_exec_task {
	my $pa_config = $_[0];
	my $id_task = $_[1];
	my $target_ip; 			# Real ip to check
	my @ip2; 			# temp array for NetAddr::IP
	my $space;			# temp var to store space of ip's for netaddr::ip
	my $query_sql; 			# for use in SQL
	my $exec_sql; 			# for use in SQL
	my @sql_data;			# for use in SQL 
	my $dbh = DBI->connect("DBI:mysql:$pa_config->{'dbname'}:$pa_config->{'dbhost'}:3306", $pa_config->{'dbuser'}, $pa_config->{'dbpass'}, { RaiseError => 1, AutoCommit => 1 });

	$query_sql = "SELECT * FROM trecon_task WHERE id_rt = $id_task";	
	$exec_sql = $dbh->prepare($query_sql);
	$exec_sql ->execute;
	if ($exec_sql->rows == 0) {
		# something wrong..
		return -1;
	}
	@sql_data = $exec_sql->fetchrow_array();
	my $status = $sql_data[10];
	my $interval = $sql_data[11];
	my $network_server_assigned = $sql_data[12];
	my $target_network = $sql_data[4];
	my $task_name = $sql_data[1];
	my $position = 0;
	my $task_type = $sql_data[3];
	my $task_ncprofile = $sql_data[6];
	my $task_group = $sql_data[8];
	my $task_create_incident = $sql_data[7];
	my $list_ip = "";
	my $list_host = "";
	my $host_found = 0;
	

	# Asign target dir to netaddr object "space"
	$space = new NetAddr::IP $target_network;
	if (!defined($space)){
		logger ($pa_config, "Bad network $target_network for task $task_name", 2);
		pandora_update_reconstatus ($pa_config, $dbh, $id_task, -1);
		pandora_task_set_utimestamp ($pa_config, $dbh, $id_task);
		return -1;
	}

	my $total_hosts= $space->num +1 ;	
	# Begin scanning main loop
	do {
		@ip2 = split(/\//,$space);
		$target_ip = $ip2[0];
		$space++; $position++;
		
		# Check ICMP for this IP
		if (($task_type == 1) && (scan_icmp ($target_ip, $pa_config->{'networktimeout'}) == 1)){
			# Is this IP listed for any agent ?
			if (pandora_check_ip ($pa_config, $dbh, $target_ip) == 0){
				$host_found ++;
				my $target_ip_resolved = resolv_ip2name($target_ip);
				$list_ip = $list_ip." ".$target_ip;
				$list_host = $list_host." ".resolv_ip2name($target_ip_resolved);
				# If has a network profile, create agent and modules
				if ($task_ncprofile > 0){
					# Create address, agent and more...
					my $target_ip_id = pandora_task_create_address ($pa_config, $dbh, $id_task, $target_ip);
					my $agent_id = pandora_task_create_agent($pa_config, $dbh, $target_ip, $target_ip_id, $task_group, $network_server_assigned, $target_ip_resolved);
					pandora_task_create_agentmodules($pa_config, $dbh, $agent_id, $task_ncprofile, $target_ip);
				}
				my $title = "[RECON] New host [$target_ip_resolved] detected on network [$target_network]";
				# Always create event about this detected IP
				pandora_event ($pa_config, $title, $task_group, 0, $dbh);
			}
		}
		my $progress = ceil($position / ($total_hosts / 100));
		pandora_update_reconstatus ($pa_config, $dbh, $id_task, $progress);		
	} while ($space < $space->broadcast); # fin del buclie principal de iteracion de Ips

	# Create incident
	if (($host_found > 0) && ($task_create_incident == 1)){
		my $my_timestamp = &UnixDate("today","%Y-%m-%d %H:%M:%S");
		my $text = "At $my_timestamp a new hosts ($host_found) has been detected by Pandora FMS Recon Server running on [".$pa_config->{'servername'}."_Recon]. This incident has been automatically created following instructions for this recon task [$task_name].\n\n";
		if ($task_ncprofile > 0){
			$text = $text."Aditionally, and following instruction for this task, agent(s) has been created, with modules assigned to network component profile [".give_network_component_profile_name ($pa_config, $dbh, $task_ncprofile)."]. Please check this agent as soon as possible to verify it.";
		}
		$text = $text . "\n\nThis is the list of IP addresses found: \n\n$list_host ";
		pandora_create_incident ( $pa_config, $dbh, "[RECON] New hosts detected", $text, 0, 0, "Pandora FMS Recon Server", $task_group);
	}
	# Mark RECON TASK as done (-1)
	pandora_update_reconstatus ($pa_config, $dbh, $id_task, -1);
	pandora_task_set_utimestamp ($pa_config, $dbh, $id_task);
}

##############################################################################
# escaneo_icmp (destination, timeout) - Do a ICMP scan 
##############################################################################
 
sub scan_icmp {
	my $dest = $_[0];
	my $l_timeout = $_[1];
 	$result = ping(hostname => $dest, timeout => $l_timeout, size => 32, count => 1);
	if ($result) {
		return 1;
	} else {
	     return 0;
	}
}


##########################################################################
# SUB resolv_ip2name (ip_address)
# return name (if could resolve) or ip of ipaddress
##########################################################################
sub resolv_ip2name {
	my $ip = $_[0];
	my $addr=inet_aton($ip);
	if ($addr) {
		my $name=gethostbyaddr($addr, AF_INET);
        	if ($name) {
	        	return $name;
	        } else {
        		return $ip;
        	}
	} else {
		return $ip;
	}
}

##########################################################################
# SUB pandora_check_ip (pa_config, dbh, ip_address)
# Return 1 if this IP exists, 0 if not
##########################################################################
sub pandora_check_ip {
	my $pa_config = $_[0];
	my $dbh = $_[1];
	my $ip_address = $_[2];

	my $query_sql = "SELECT * FROM taddress WHERE ip = '$ip_address' ";
	my $exec_sql = $dbh->prepare($query_sql);
	$exec_sql ->execute;
	if ($exec_sql->rows != 0) {
		$exec_sql->finish();
		return 1;
	} else {
		$exec_sql->finish();
		return 0;
	}
}

##########################################################################
# SUB pandora_update_reconstatus (pa_config, dbh, id_task, status)
# Update recontask status flag
##########################################################################
sub pandora_update_reconstatus {
	my $pa_config = $_[0];
	my $dbh = $_[1];
	my $id_task = $_[2];
	my $status  = $_[3];

	my $query_sql2 = "UPDATE trecon_task SET status = $status WHERE id_rt = $id_task";
	$dbh->do($query_sql2);
}

##########################################################################
# SUB pandora_task_set_utimestamp (pa_config, dbh, id_task)
# Update utimestamp to current timestamp
##########################################################################
sub pandora_task_set_utimestamp {
	my $pa_config = $_[0];
	my $dbh = $_[1];
	my $id_task = $_[2];
	my $my_timestamp = &UnixDate("today","%Y-%m-%d %H:%M:%S");
	my $my_utimestamp = &UnixDate($my_timestamp, "%s"); # convert from human to integer
	
	my $query_sql2 = "UPDATE trecon_task SET utimestamp = '$my_utimestamp' WHERE id_rt = $id_task";
	$dbh->do($query_sql2);
}

##########################################################################
# SUB pandora_task_create_address (pa_config, dbh, id_task, address)
# Add address to table taddress, return ID of created record
##########################################################################
sub pandora_task_create_address {
	my $pa_config = $_[0];
	my $dbh = $_[1];
	my $id_task = $_[2];
	my $ip_address = $_[3];	
	my $query_sql2 = "INSERT INTO taddress (ip) VALUES ('$ip_address')";
	$dbh->do ($query_sql2);
	my $lastid = $dbh->{'mysql_insertid'};
	return $lastid;
}

##########################################################################
# SUB pandora_task_create_agent (pa_config, dbh, target_ip, target_ip_id,
#				 id_group, network_server_assigned, name)
# Create agent, and associate address to agent in taddress_agent table.
# it returns created id_agent.
##########################################################################
sub pandora_task_create_agent {  
	my $pa_config = $_[0];
	my $dbh = $_[1];
	my $target_ip = $_[2];
	my $target_ip_id = $_[3];
	my $id_group = $_[4];
	my $id_server= $_[5];
	my $name = $_[6];

	logger($pa_config,"Recon Server: Creating agent for ip $target_ip ",2);
	my $query_sql2 = "INSERT INTO tagente (nombre, direccion, comentarios, id_grupo, id_os, agent_type, id_server, intervalo) VALUES  ('$name', '$target_ip', 'Autogenerated by Pandora FMS Recon Server', $id_group, 11, 1, $id_server, 300)";
	$dbh->do ($query_sql2);
	my $lastid = $dbh->{'mysql_insertid'};
	my $query_sql3 = "INSERT INTO taddress_agent (id_a, id_agent) values ($target_ip_id, $lastid)";
	$dbh->do($query_sql3);
	return $lastid;
}

##########################################################################
# SUB pandora_task_create_agentmodules (pa_config, dbh, agent_id, ncprofile, ipaddress)
# Create modules from a network component profile and associated to given agent
##########################################################################
sub pandora_task_create_agentmodules {
	my $pa_config = $_[0];
	my $dbh = $_[1];
	my $agent_id = $_[2];
	my $ncprofile_id = $_[3];
	my $ip_adress = $_[4];
	my @sql_data;
	
	# Search each network component that belongs to ncprofile_id
	my $query_sql = "SELECT * FROM tnetwork_profile_component where id_np = $ncprofile_id ";
	my $exec_sql = $dbh->prepare($query_sql);
	$exec_sql ->execute;
	while (@sql_data = $exec_sql->fetchrow_array()) {
		my $id_nc = $sql_data[1];
		my $query_sql2 = "SELECT * FROM tnetwork_component where id_nc = $id_nc ";
		my $exec_sql2 = $dbh->prepare($query_sql2);
		$exec_sql2 ->execute;
		if ($exec_sql2->rows != 0) {
			my @sql_data2 = $exec_sql2->fetchrow_array();
			my $name = "";
			$name = $sql_data2[1];
			my $description = "Autocreated by Pandora FMS Recon Server";
			$description = $sql_data2[2];
			my $type = "1";
			$type = $sql_data2[4];
			my $max = 0;
			$max = $sql_data2[5];
			my $min = 0;
			$min = $sql_data2[6];
			my $interval = 300;
			$interval = $sql_data2[7];
			my $tcp_port = "";
			$tcp_port = $sql_data2[8];
			my $tcp_send = "";
			$tcp_send = $sql_data2[9];
			my $tcp_rcv = "";
			$tcp_rcv = $sql_data2[10];
			my $snmp_community = "public";
			$snmp_community = $sql_data2[11];
			my $snmp_oid = "";
			$snmp_oid = $sql_data2[12];
			my $id_module_group = 0;
			$id_module_group = $sql_data2[13];
			
			my $query_sql3 = "INSERT INTO tagente_modulo (id_agente, id_tipo_modulo, descripcion, nombre, max, min, module_interval, tcp_port, tcp_send, tcp_rcv, snmp_community, snmp_oid, ip_target, id_module_group, flag ) VALUES ( $agent_id, $type, '$description', '$name', $max, $min, $interval, $tcp_port, '$tcp_send', '$tcp_rcv', '$snmp_community', '$snmp_oid', '$ip_adress', $id_module_group, 1)";
			$dbh->do($query_sql3);
			logger($pa_config,"Recon Server: Creating module $name for agent $ip_adress",3);
		}
		$exec_sql2->finish();
	}
	$exec_sql->finish();
}

