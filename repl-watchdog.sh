#!/bin/bash
# automatic MySQL failover 
# To be executed on the backends

VERSION="1.2"
[[ "x$@x" =~ .*--version.* ]] && echo "Version : ${VERSION}" && exit 0
          


##################
### parameters ###
##################
LOG=true
VERBOSE=true

# target sockets 
ROUTER="127.0.0.1:7001"
HOST_A="10.75.8.99:3306"
HOST_B="10.75.8.100:3306"

# repl-watchdog username in database ( GRANT ALL PRIVILEGES ON *.* TO '${MY_USER}'@'%' IDENTIFIED BY '${MY_PASSWD}'; )
MY_USER="repl-watchdog"
MY_PASSWD='fae4669d09a763a2a937adbabb555f42'

# daemon options 
PIDFILE="/var/log/mysql-failover.pid"
WORKINGDIR="/tmp/repl-data"
# BDD Server local configuration
BDD_PEER="bdd-peer" # configured in BDD /etc/hosts 
BDD_PEER_PORT=3306 
BDD_PEER_USER='repl'  # GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* TO '${BDD_PEER_USER}'@'%' IDENTIFIED BY '${BDD_PEER_PASSWORD}';
BDD_PEER_PASSWORD='69855294b41c7b61f286368777cc017f'



###################################################################################################################################
############################# do not edit anything below this line unless you know what you are doing ############################# 
###################################################################################################################################
 
#################
### functions ###
#################

function log_msg() {
  $LOG && logger -p local0.notice repl-watchdog: $1
  $VERBOSE && echo "notice : $1"  
}

function log_warning() {
  $LOG &&logger -p local0.warning repl-watchdog: $1
  $VERBOSE && echo "warning : $1"  
}

function stop_error() {
  $LOG &&logger -p local0.error repl-watchdog: $1
  $VERBOSE && echo "error : $1"
  [[ -f ${PIDFILE} ]] && rm -f ${PIDFILE}
  exit 1
}


############
### main ###
############


### check usage and delay execution 
[[ -f ${PIDFILE} ]] && log_warning "process already running, exiting" && exit 0 || echo $$ > ${PIDFILE}
! [[ "x$@x" =~ .*--now.* ]] && sleep $(( $( date +%N | head -c 2 ) * 3 ))



### declare and compute local vars ###

SOCK_R=(${ROUTER/:/ })
SOCK_A=(${HOST_A/:/ })
SOCK_B=(${HOST_B/:/ })
[[ "x${SOCK_A[1]}x" == "xx"  ]] && SOCK_A[1]=3306
[[ "x${SOCK_B[1]}x" == "xx"  ]] && SOCK_B[1]=3306
[[ "x${SOCK_R[1]}x" == "xx"  ]] && SOCK_R[1]=3306


#A_UP=true      # server connection up
#A_RO=false      # server read-only
A_TARGET=false  # is router target
A_MASTER=false  # is repl master

#B_UP=true
#B_RO=false
B_TARGET=false
B_MASTER=false

REPL_KO=false

! [ -x /usr/bin/mysql ] && stop_error "package mysql-client is needed"
! [ -x /bin/gzip ] && stop_error "package gzip is needed"
QUERY_R="/usr/bin/mysql -h ${SOCK_R[0]} -P ${SOCK_R[1]} --user=${MY_USER} -B -e "
QUERY_A="/usr/bin/mysql -h ${SOCK_A[0]} -P ${SOCK_A[1]} --user=${MY_USER} -B -e "
QUERY_B="/usr/bin/mysql -h ${SOCK_B[0]} -P ${SOCK_B[1]} --user=${MY_USER} -B -e "
DUMP_A="/usr/bin/mysqldump -h ${SOCK_A[0]} -P ${SOCK_A[1]} --user=${MY_USER} --all-databases --single-transaction --master-data=1 --triggers --routines --events" 
DUMP_B="/usr/bin/mysqldump -h ${SOCK_B[0]} -P ${SOCK_B[1]} --user=${MY_USER} --all-databases --single-transaction --master-data=1 --triggers --routines --events"
IMPORT_A="/usr/bin/mysql -h ${SOCK_A[0]} -P ${SOCK_A[1]} --user=${MY_USER} "
IMPORT_B="/usr/bin/mysql -h ${SOCK_B[0]} -P ${SOCK_B[1]} --user=${MY_USER} "

# failover process queries
FAILOVER_SET_CANDIDATE="create database if not exists ongoing_failover; create table if not exists ongoing_failover.status (event varchar(100)); insert into ongoing_failover.status values('SCAN ${HOSTNAME}');"
FAILOVER_GET_MASTER="select event from ongoing_failover.status where event like 'SCAN %' limit 1;"
FAILOVER_SET_MASTER="insert into ongoing_failover.status values('MAST ${HOSTNAME}');"
FAILOVER_SET_FOLLOWER="insert into ongoing_failover.status values('FOLO ${HOSTNAME}');"
FAILOVER_IS_FOLLOWER="select event from ongoing_failover.status where event like 'FOLO ${HOSTNAME}' limit 1;"
FAILOVER_SET_MASTER_OK="insert into ongoing_failover.status values('MAOK ${HOSTNAME}');"
FAILOVER_IS_MASTER_OK="select event from ongoing_failover.status where event like 'MAOK %' limit 1;"
FAILOVER_SET_FOLLOWER_OK="insert into ongoing_failover.status values('FOOK ${HOSTNAME}');"
FAILOVER_SET_TARGET_A="insert into ongoing_failover.status values('TARG ${HOST_A}');"
FAILOVER_SET_TARGET_B="insert into ongoing_failover.status values('TARG ${HOST_B}');"
FAILOVER_GET_TARGET="select event from ongoing_failover.status where event like 'TARG %' limit 1;"
FAILOVER_SETOP_FAIL="insert into ongoing_failover.status values('OPER fail');"
FAILOVER_SETOP_REPL="insert into ongoing_failover.status values('OPER repl');"
FAILOVER_GETOP="select event from ongoing_failover.status where event like 'OPER %' limit 1;"


export MYSQL_PWD=${MY_PASSWD}

### get router target ###
QUERY="SELECT @@server_id;"
      ##################
      ### DOWN state ### 
      ##################

RS_R=$( ${QUERY_R} "${QUERY}" ) ; ! [[ "x${RS_R}x" =~ x@@server_id[[:space:]][0-9]x ]] && stop_error "unable to connect ${ROUTER}"
RS_A=$( ${QUERY_A} "${QUERY}" ) ; ! [[ "x${RS_A}x" =~ x@@server_id[[:space:]][0-9]x ]] && stop_error "${HOST_A} is DOWN !" #&& A_UP=false
RS_B=$( ${QUERY_B} "${QUERY}" ) ; ! [[ "x${RS_B}x" =~ x@@server_id[[:space:]][0-9]x ]] && stop_error "${HOST_B} is DOWN !" #&& B_UP=false

if [[ "x${RS_R}x" == "x${RS_A}x" ]]; then
  A_TARGET=true
elif [[ "x${RS_R}x" == "x${RS_B}x" ]]; then
  B_TARGET=true
else
  log_error "could not identify router target"
  exit 1
fi


### get replication status ###

QUERY="show slave status\G;"

RS=$( ${QUERY_A} "${QUERY}" | wc -l )
[[ ${RS} -eq 0 ]] && A_MASTER=true

RS=$( ${QUERY_B} "${QUERY}" | wc -l )
[[ ${RS} -eq 0 ]] && B_MASTER=true
  
${A_MASTER} && ${B_MASTER} && stop_error "both servers are replication masters"
! ${A_MASTER} && ! ${B_MASTER} && stop_error "both servers are replication slaves"

RS=0
${A_MASTER} && RS=$( ${QUERY_B} "${QUERY}" | grep -c "Last_Errno: 0"  )
${B_MASTER} && RS=$( ${QUERY_A} "${QUERY}" | grep -c "Last_Errno: 0"  )
[[ ${RS} -ne 1 ]] && REPL_KO=true 

### get readonly status ###
#QUERY="SELECT @@global.read_only;"
#
#RS_A=$( ${QUERY_A} "${QUERY}" ) ; TMP_A=$( echo $RS_A |cut -d" " -f 2 )
#RS_B=$( ${QUERY_B} "${QUERY}" ) ; TMP_B=$( echo $RS_B |cut -d" " -f 2 )
#! [[ "x${TMP_A}${TMP_B}x" =~ x[0-1][0-1]x ]] && echo "unable to get read-only status" && exit 1
#[[ ${TMP_A} -eq 1 ]] && A_RO=true || A_RO=false
#[[ ${TMP_B} -eq 1 ]] && B_RO=true || B_RO=false



# router target is the slave. 
if ( ( ${A_MASTER} && ${B_TARGET} ) || ( ${B_MASTER} && ${A_TARGET} ) ); then

      ######################
      ### FAILOVER state ### 
      ######################

  if ( ${A_MASTER} && ${B_TARGET} ); then
    NEW_MASTER=${HOST_B}
    NEW_SLAVE=${HOST_A}
    QUERY_NEW_MASTER=${QUERY_B}
    QUERY_NEW_SLAVE=${QUERY_A}
    FAILOVER_SET_NEW_TARGET=${FAILOVER_SET_TARGET_B}
    DUMP_NEW_MASTER=${DUMP_B}
    IMPORT_NEW_SLAVE=${IMPORT_A}
    NEW_ROUTER_CONFIG="${SOCK_B[0]},${SOCK_A[0]}"
    REVERT_ROUTER_CONFIG="${SOCK_A[0]},${SOCK_B[0]}"
  else
    NEW_MASTER=${HOST_A}
    NEW_SLAVE=${HOST_B}
    QUERY_NEW_MASTER=${QUERY_A}
    QUERY_NEW_SLAVE=${QUERY_B}
    FAILOVER_SET_NEW_TARGET=${FAILOVER_SET_TARGET_A}
    DUMP_NEW_MASTER=${DUMP_A}
    IMPORT_NEW_SLAVE=${IMPORT_B}
    NEW_ROUTER_CONFIG="${SOCK_A[0]},${SOCK_B[0]}"
    REVERT_ROUTER_CONFIG="${SOCK_B[0]},${SOCK_A[0]}"
  fi
  
  log_warning "failover detected, ${NEW_MASTER} switched to master state"
  
  # lock
  RS=$( ${QUERY_NEW_MASTER} "${FAILOVER_SET_CANDIDATE}" )
  RS=$( ${QUERY_NEW_MASTER} "${FAILOVER_GET_MASTER}" )
  if [[ "x${RS}x" =~ .*${HOSTNAME}.* ]]; then
    # we got the shared lock, we do the job
    
    RS=$( ${QUERY_MASTER} "${FAILOVER_GETOP}" | wc -l )
    if [[ ${RS} -eq 0 ]]; then
    
      RS=$( ${QUERY_NEW_MASTER} "${FAILOVER_SET_MASTER}" )
      RS=$( ${QUERY_NEW_MASTER} "${FAILOVER_SETOP_FAIL}" )
      RS=$( ${QUERY_NEW_MASTER} "${FAILOVER_SET_NEW_TARGET}" )
      
          
      log_msg "promoting slave as new master"
      QUERY="stop slave;" ; RS=$( ${QUERY_NEW_MASTER} "${QUERY}" )
      QUERY="reset slave all;" ; RS=$( ${QUERY_NEW_MASTER} "${QUERY}" )
      QUERY="reset master;" ; RS=$( ${QUERY_NEW_MASTER} "${QUERY}" )
        
      log_msg "dumping all databases"
      TS=$( date +%s )
      mkdir -p ${WORKINGDIR}/repl-watchdog_${TS} >/dev/null 2>&1
      $DUMP_NEW_MASTER > ${WORKINGDIR}/repl-watchdog_${TS}/dump.sql
    
      log_msg "importing databases"
      QUERY="reset master;" ; RS=$( ${QUERY_NEW_SLAVE} "${QUERY}" )
      $IMPORT_NEW_SLAVE < ${WORKINGDIR}/repl-watchdog_${TS}/dump.sql
    
      log_msg "restarting replication"
      QUERY="flush privileges;" ; RS=$( ${QUERY_NEW_SLAVE} "${QUERY}" )
      QUERY="CHANGE MASTER TO MASTER_HOST ='${BDD_PEER}', MASTER_PORT=${BDD_PEER_PORT}, MASTER_USER='${BDD_PEER_USER}', MASTER_PASSWORD='${BDD_PEER_PASSWORD}', MASTER_AUTO_POSITION=1;" ; RS=$( ${QUERY_NEW_SLAVE} "${QUERY}" )
      QUERY="start slave;" ; RS=$( ${QUERY_NEW_SLAVE} "${QUERY}" )
     
      log_msg "resetting mysqlrouter order"
      sed -i "s/^destinations.*=.*$/destinations = ${NEW_ROUTER_CONFIG}/g" /etc/mysqlrouter/mysqlrouter.ini
      systemctl restart mysqlrouter
  
      RS=$( ${QUERY_NEW_MASTER} "${FAILOVER_SET_MASTER_OK}" )
    else
      log_warning "another operation is running on this server"
    fi
  else
    # check if we are already declared as slave
    RS_A=$( ${QUERY_A} "${FAILOVER_IS_FOLLOWER}" | wc -l )
    RS_B=$( ${QUERY_B} "${FAILOVER_IS_FOLLOWER}" | wc -l )
    if [[ $(( ${RS_A} + ${RS_A} )) -eq 0 ]]; then
      log_msg "declaring as a slave of this failover"
      RS_A=$( ${QUERY_A} "${FAILOVER_SET_FOLLOWER}")
      RS_B=$( ${QUERY_B} "${FAILOVER_SET_FOLLOWER}")
    fi

    # check target
    RS_A=""
    RS_B=""
    while [[ "x${RS_A}${RS_B}x" == "xx" ]]; do
      RS_A=$( ${QUERY_A} "${FAILOVER_GET_TARGET}" )
      RS_B=$( ${QUERY_B} "${FAILOVER_GET_TARGET}" )
      if [[ "x${RS_A}${RS_B}x" =~ .*${NEW_SLAVE}.* ]]; then
        log_msg "resetting mysqlrouter order"
        sed -i "s/^destinations.*=.*$/destinations = ${REVERT_ROUTER_CONFIG}/g" /etc/mysqlrouter/mysqlrouter.ini
      fi
    done

    # rearm mysqlrouter
    systemctl restart mysqlrouter
    RS_A=$( ${QUERY_A} "${FAILOVER_SET_FOLLOWER_OK}" )
    RS_B=$( ${QUERY_B} "${FAILOVER_SET_FOLLOWER_OK}" )
    
  fi
elif ${REPL_KO}; then
  # router target is the master
    
      #####################
      ### RECOVER state ### 
      #####################

  if ${A_MASTER}; then
    QUERY_MASTER="${QUERY_A}"
    QUERY_SLAVE="${QUERY_B}"    
    DUMP_MASTER=${DUMP_A}
    DUMP_SLAVE=${DUMP_B}    
    SOCK_SLAVE=${SOCK_B[0]}
    IMPORT_SLAVE=${IMPORT_B}
  else
    QUERY_MASTER="${QUERY_B}"
    QUERY_SLAVE="${QUERY_A}"
    DUMP_MASTER=${DUMP_B}
    DUMP_SLAVE=${DUMP_A}
    SOCK_SLAVE=${SOCK_A[0]}
    IMPORT_SLAVE=${IMPORT_A}
  fi

     
  # lock
  RS=$( ${QUERY_MASTER} "${FAILOVER_SET_CANDIDATE}" )
  RS=$( ${QUERY_MASTER} "${FAILOVER_GET_MASTER}" )
  if [[ "x${RS}x" =~ .*${HOSTNAME}.* ]]; then
    # we got the shared lock, we check if a failover operation is not running
    RS=$( ${QUERY_MASTER} "${FAILOVER_GETOP}" | wc -l )
    if [[ ${RS} -eq 0 ]]; then
    
      RS=$( ${QUERY_MASTER} "${FAILOVER_SET_MASTER}" )
      RS=$( ${QUERY_MASTER} "${FAILOVER_SETOP_REPL}" )
  
      # case : we are on the master but the replication failed. This is a database corruption, some data can be lost.
      # we must recover the replication, 
  
      log_warning "replication failed, database may be corrupted"
  
      TS=$( date +%s )  
  
      log_msg "stopping replication"
      QUERY="stop slave;" ; RS=$( ${QUERY_SLAVE} "${QUERY}" )
      QUERY="reset slave all;" ; RS=$( ${QUERY_SLAVE} "${QUERY}" )
      
      log_msg "dumping all databases"
      $DUMP_SLAVE | /bin/gzip -9 > ${WORKINGDIR}/replfailure_${SOCK_SLAVE}_$(date +%Y%m%d%H%M%S).sql.gz
      mkdir -p ${WORKINGDIR}/repl-watchdog_${TS} >/dev/null 2>&1
      $DUMP_MASTER > ${WORKINGDIR}/repl-watchdog_${TS}/dump.sql
      log_warning "corrupted database stored to ${WORKINGDIR}/replfailure_${SOCK_SLAVE}_$(date +%Y%m%d%H%M%S).sql.gz"
          
      log_msg "importing databases"
      QUERY="reset master;" ; RS=$( ${QUERY_SLAVE} "${QUERY}" )
      $IMPORT_SLAVE < ${WORKINGDIR}/repl-watchdog_${TS}/dump.sql
    
      log_msg "restarting replication"
      QUERY="flush privileges;" ; RS=$( ${QUERY_SLAVE} "${QUERY}" )
      QUERY="CHANGE MASTER TO MASTER_HOST ='${BDD_PEER}', MASTER_PORT=${BDD_PEER_PORT}, MASTER_USER='${BDD_PEER_USER}', MASTER_PASSWORD='${BDD_PEER_PASSWORD}', MASTER_AUTO_POSITION=1;" ; RS=$( ${QUERY_SLAVE} "${QUERY}" )
      QUERY="start slave;" ; RS_B=$( ${QUERY_SLAVE} "${QUERY}" )
  
      log_msg "replication done, removing lock"
      QUERY="drop database ongoing_failover;" ; RS=$( ${QUERY_MASTER} "${QUERY}" )
      rm -rf ${WORKINGDIR}/repl-watchdog_* >/dev/null 2>&1
    
    else
      log_warning "another operation is running on this server"
    fi
  fi
else
  
      ################
      ### OK state ### 
      ################

  # free shared lock if any
  ${A_MASTER} && QUERY_MASTER="${QUERY_A}" || QUERY_MASTER="${QUERY_B}" 
  
  QUERY="select SCHEMA_NAME from INFORMATION_SCHEMA.SCHEMATA where SCHEMA_NAME = 'ongoing_failover';" ; RS=$( ${QUERY_MASTER} "${QUERY}" |wc -l )
  [[ $RS -ne 0 ]] && RS=$( ${QUERY_MASTER} "${FAILOVER_GET_MASTER}" )

  if [[ "x${RS}x" =~ .*${HOSTNAME}.* ]]; then

    QUERY="select sum( case when event like 'FOLO %' then 1 when event like 'FOOK %' then -1 else 0 end ) as score from ongoing_failover.status;"
    RS=$( ${QUERY_MASTER} "${QUERY}" | grep -v 'score' )
    
    if [[ $RS -le 0 ]]; then
      log_msg "all followers are up to date, removing lock"
      
      QUERY="drop database ongoing_failover;" ; RS=$( ${QUERY_MASTER} "${QUERY}" )
      rm -rf ${WORKINGDIR}/repl-watchdog_* >/dev/null 2>&1
        
      log_msg "replication and failover ok"    
    else
      log_warning "replication and failover ok but some followers are not up to date"          
    fi
    
  else
    log_msg "replication and failover ok"
  fi
fi

# cleanup   
[[ -f ${PIDFILE} ]] && rm -f ${PIDFILE} 

 