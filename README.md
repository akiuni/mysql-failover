# mysql-failover
automatic failover script for mysql

I have created this repository so as to share and improve a little script intended to automate MySQL failover operations.
At this time, it is a simple BASH script as a proof of concept. If it becomes reliable and usefull for the community, I'd like to port in to C programming ( based on the mysql libraries ).

So feel free to download, test, and make propositions

Best regards
Julien

## How does this script works

This script is called repl-watchdog. It is intended to be run on each backend equiped by a local mysqlrouter which is configured to contact a Master-Slave MySQL Cluster :

    Backend_A --' local mysqlrouter --' MySQL Master-Slave cluster : (BddHost_A BddHost_B)
    Bachend_B --' local mysqlrouter /
    Bachend_C --' local mysqlrouter /
    ...


## Prerequisites

repl-watchdog needs mysql-client and gzip packages
 
Each backend mysqlrouter has the following configuration :

    [routing:mysql_failover]
    bind_address = 0.0.0.0:7001
    connect_timeout = 3
    client_connect_timeout = 9
    destinations = ${IP_BDDSERVER_A},${IP_BDDSERVER_B}
    mode = read-write

You can change bind_address to localhost and to another listening port, but remember to adjust repl-watchdog accordingly :

    ROUTER="127.0.0.1:7001"

You **must** change destinations to the BddHost_A and BddHost_B IP addresses of your servers and adjust repl-watchdog.

    HOST_A="${IP_BDDSERVER_A}:3306"
    HOST_B="${IP_BDDSERVER_B}:3306"


The Master-Slave MySQL cluster must be configred with GTID enabled and RW on both Master and Slave. Hence, the following lines are requiered in my.cnf :

    gtid_mode=ON
    enforce_gtid_consistency=ON

Two users are needed in the database cluster. One for replication and another one for repl-watchdog. repl-watchdog user must have replication, dump and import rights, adjust repl-watchdog accordingly :

    GRANT ALL PRIVILEGES ON *.* TO '${MY_USER}'@'%' IDENTIFIED BY '${MY_PASSWD}';
    GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${BDD_PEER_USER}'@'%' IDENTIFIED BY '${BDD_PEER_PASSWORD}';

Lastly, you must declare the BDD peer on each database server by registering ${BDD_PEER} in /etc/hosts.

 
## Installation


First make sure all variables are properly set in your repl-watchdoc script. Especially the ${WORKINGDIR} must exist and have enough space to get at least 2 database dumps.

 
You can run repl-watchdog directly from command line :

    ./repl-watchdog --now 

You can also create a crontab to execute it all the 10 minutes :

    */10 * * * * root /path/to//repl-watchdog ' /dev/null  2'&1  

## Protocol description

each repl-watchdog script (running of the backends) will test the cluster status. 4 states can be identified :

* down state : One of the bdd server is down. repl-watchdog won't do anything in this state.
* failover state : the queries are sent to the slave database server. This means that the master server has crashed, repl-watchdog will promote the slave as master and restart the replication on the new slave.
* recover state : the queries are sent to the master database server but the replication is broken on the slave. repl-watchdog will recover the replication.
* ok state: all is fine, queries are redirected to master database server and replication is ok on the slave.

 
### failover state

In failover state, the repl-watchdog will create the database *ongoing_failover* and the table *status* inside so as to communicate with other repl-watchdog scripts. 

* operation master election

Each repl-watchdog script send a "SCAN 'hostname'" status. The first record becomes the master of operations and confirms with a "MAST 'hostname'" status

* followers declarations

Each repl-watchdog  which have not beeing elected as master will declare itself as a follower : "FOLO 'hostname"

* do the job

the operation master first send a "TARG 'socket'" status to inform the followers which is the new master. Then, it promotes the bdd slave server as new master, copy the database on the new slave, restart the replication and reset its local mysqlrouter status. Once all finished, it sends a "MAOK 'hostname'" status       

the followers will wait for the "TARG" status and reset their local mysqlrouter configuration accordingly. Once finished, send a "FOOK 'hostname'" status       

* terminate the operation

When the operation master detects that all folowers sent their "FOOK" status, remove the ongoing_failover database.


### recover state

In failover state, the repl-watchdog will create the database *ongoing_failover* and the table *status* inside so as to communicate with other repl-watchdog scripts. 

* operation master election

Each repl-watchdog script send a "SCAN 'hostname'" status. The first record becomes the master of operations and confirms with a "MAST 'hostname'" status

* do the job
 
The operation master will first make a backup of the corrupted database in its working directory. Then, it will import he master database and restart the replication. Once all is done, it removes the ongoing_failover database.


### status signals

Here is a list of possible signals in the ongoing_failover database :

    | Signal              |     Description                                                        |
    | ------------------- |: ----------------:                                                     |
    | SCAN 'host'         | 'host' is candidate for operation master election.                     |
    | MAST 'host'         | 'host' is the operation master.                                        |
    | FOLO 'host'         | 'host' is follower on this operation.                                  |
    | MAOK 'host'         | master finished the job, it will now wait for the followers to finish. |
    | FOOK 'host'         | follower finished the job.                                             |
    | TARG 'socket'       | The master informs followers the new database master server.           |
    | OPER 'fail or repl' | The master informs what kind of operation is running.                  |
 


 



      