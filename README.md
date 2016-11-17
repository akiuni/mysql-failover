# mysql-failover
automatic failover script for mysql

I have created this repository so as to share and improve a little script intended to automate MySQL failover operations.
At this time, it is a simple BASH script as a proof of concept. If it becomes reliable and usefull for the community, I'd like to port in to C programming ( based on the mysql libraries ).

So feel free to download, test, and make propositions

Best regards
Julien

## How does this script works

This script is called repl-watchdog. It is intended to be run on each backend equiped by a local mysqlrouter which is configured to contact a Master-Slave MySQL Cluster :

    Backend_A --> local mysqlrouter --> MySQL Master-Slave cluster : (BddHost_A BddHost_B)
    Bachend_B --> local mysqlrouter /
    Bachend_C --> local mysqlrouter /
    ...


## Prerequisites

repl-watchdog needs mysql-client and gzip packages
 
Each backend mysqlrouter has the following configuration :

`[routing:mysql_failover]
bind_address = 0.0.0.0:7001
connect_timeout = 3
client_connect_timeout = 9
destinations = 10.75.8.100,10.75.8.99
mode = read-write`

You can change bind_address to localhost and to another listening port, but remember to adjust repl-watchdog accordingly :
`ROUTER="127.0.0.1:7001"`

You **must** change destinations to the BddHost_A and BddHost_B IP addresses of your servers and adjust repl-watchdog.
`HOST_A="10.75.8.99:3306"
HOST_B="10.75.8.100:3306"`


The Master-Slave MySQL cluster must be configred with GTID enabled and RW on both Master and Slave. Hence, the following lines are requiered in my.cnf :
`gtid_mode=ON
enforce_gtid_consistency=ON`

Two users are needed in the database cluster. One for replication and another one for repl-watchdog. repl-watchdog user must have replication, dump and import rights, adjust repl-watchdog accordingly :
`GRANT ALL PRIVILEGES ON *.* TO '${MY_USER}'@'%' IDENTIFIED BY '${MY_PASSWD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${BDD_PEER_USER}'@'%' IDENTIFIED BY '${BDD_PEER_PASSWORD}';`

Lastly, you must declare the BDD peer on each database server by registering ${BDD_PEER} in /etc/hosts.

 
## Installation

You can run repl-watchdog directly from command line :

`./repl-watchdog --now` 

You can also create a crontab to execute it all the 10 minutes :
`*/10 * * * * root /path/to//repl-watchdog > /dev/null  2>&1`  





  


      