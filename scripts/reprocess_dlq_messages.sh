#!/bin/bash

# Assumption

# 1. The original queue name is the same as its DLQ string minus the DLQ piece 

# Considerations
# 1. The intention is for this process to be executed manually, therefore
#    all feedback will come via stdout/stderr

function Log () {

    if [ $# -ne 2 ] ; then
        echo "Log function requires two arguments - the log type and the message"
        echo "i.e Log Error \"Unable to find file - process exiting\""
        echo "Logs of type ERROR will additionally script abend"
        exit 1
    fi

    UpperCaseLogType=$(echo "$1" | tr "[a-z]" "[A-Z]")

    # Future Proofing
    case "$UpperCaseLogType" in
        "ERROR" ) ScriptAbend=Yes ;;
    esac

    echo "[$0] [$(date)] [$UpperCaseLogType] $2 "

    [ $ScriptAbend ] && exit 1

    return

}

function Usage () {

    clear

    echo "Usage information for script [$0]"

    echo ""
    echo -e "\t\t\t -h ; this help"
    echo -e "\t\t\t -f <Queue to transfer messages FROM> -t <Queue to transfer messages TO>"
    echo -e "\t\t\t -a ; transfer ALL messages from each DLQ back to the originating queue"
    echo ""
    echo -e "\t i.e $0 -f USERS.cid-in-cases.DLQ -t USERS.cid-in-cases"
    echo ""

    echo -e "\tNOTE : if specifying -f you MUST also specify -t and vice versa"
    echo -e "\tThe use of -a and -f/-t are mutually exclusive"
    echo ""

    exit

}

function MoveMessages () { 

    if [ $# -ne 2 ] ; then 
        Log Info "Function MoveMessages requires two arguments, the queue to move the messages from and the queue to move the messages to"
        Log Error "i.e MoveMessages <FromQueue> <ToQueue>"]
    else 
        SourceQueue=$1
        DestQueue=$2
    fi

    Log Info "Moving [$MessagesOnQueue] from queue [$SourceQueue] to queue [$DestQueue]"
    java -jar $ACTIVEMQ_MANAGER_JAR --move-queue $SourceQueue $DestQueue

    if [ $? -ne 0 ] ; then
        Log Info "Transfer of message failed from queue [$SourceQueue] to queue [$DestQueue]"
    fi

    return 

}


# MAIN

# Gather options from the command line

while getopts "hf:t:a" arg; do

    case $arg in

        h) Usage ;;

        f) FromQueue=$OPTARG
           # From Queue MUST be a DLQ queue
           if $( ! echo "$FromQueue" | grep DLQ >/dev/null 2>&1) ; then
               Log Error "From queue is not a correctly formatted DLQ [$OPTARG]. Please retry"
           fi ;;

        t) ToQueue=$OPTARG   ;;

        a) AllQueues=true ;;

      esac
done

ACTIVEMQ_HOME=/opt/activemq
ACTIVEMQ_BIN_DIR=$ACTIVEMQ_HOME/bin
ACTIVEMQ_SCRIPTS_DIR=$ACTIVEMQ_HOME/scripts
ACTIVEMQ_ADMIN_SCRIPT=$ACTIVEMQ_BIN_DIR/activemq
ACTIVEMQ_MANAGER_JAR=$ACTIVEMQ_SCRIPTS_DIR/activemq-manager.jar

# Validate commamnd line options
if [[ "$FromQueue" && -z "$ToQueue" || "$ToQueue" && -z "$FromQueue" || "$FromQueue" && "$AllQueues" || "$ToQueue" && "$AllQueues" ]] ; then
    Usage
fi

# Validate prerequisites
ACTIVEMQ_PID=$(ps -ef| grep [a]ctivemq | awk ' { print $2 } ')
if [ -z $ACTIVEMQ_PID ] ; then
    Log Error "activemq process is not running - exiting process"
else
    Log Info "activemq is running under process id [$ACTIVEMQ_PID]"
fi

# ACTIVEMQ
if [ ! -x $ACTIVEMQ_ADMIN_SCRIPT ] ; then
    Log Error "ACTIVEMQ_ADMIN_SCRIPT not found or not executable - exiting process"
fi

if [ ! -r $ACTIVEMQ_MANAGER_JAR ] ; then
    Log Error "$ACTIVEMQ_MANAGER_JAR not found - exiting process"
fi

# JAVA
if ! $(which java >/dev/null 2>&1) ; then
    Log Error "Unable to find Java - process exiting"
fi

# Do the work ...

if [ "$AllQueues" ] ; then

    declare -a PriorityQueueArray

    PriorityQueueArray=(USERS.cid-in-people USERS.cid-in-cases USERS.cid-in-person_case USERS.crs-in-namedperson)

    for PriorityQueue in ${PriorityQueueArray[@]}
    do
        FromQueue=$PriorityQueue.DLQ
        DstatRecordDLQ=$($ACTIVEMQ_ADMIN_SCRIPT dstat | grep $FromQueue)
        MessagesOnQueue=$(echo $DstatRecordDLQ | awk ' { print $2 } ')

        if [ "$DstatRecordDLQ" ] ; then
            if [ "$MessagesOnQueue" -ne 0 ] ; then

                # Perform the transfer
                MoveMessages $FromQueue $PriorityQueue

                # Hold off until the queue is empty
                while (true)
                do
                    UnprocesedMessagesCount=$($ACTIVEMQ_ADMIN_SCRIPT dstat | awk -v PriorityQueue="^"$PriorityQueue"$" ' {if ($1 ~ PriorityQueue) print $2 } ')

                    if [ "$UnprocesedMessagesCount" -ne 0 ] ; then
                        echo "Processing queue [$PriorityQueue] [$UnprocesedMessagesCount] messages remaining ..."
                        sleep 3
                    else
                        continue
                    fi
                done
            else
                Log Info "No messages found on queue [$FromQueue]"
            fi
        else
            Log Info "Unable to find queue name [ $FromQueue ] - not processing"
        fi

    done

    $ACTIVEMQ_ADMIN_SCRIPT dstat | grep "^USERS.*.DLQ" | while read _line
    do
        FromQueue=$(echo $_line | awk ' { print $1 } ')
        ToQueue=$(echo $FromQueue | sed -e 's!DLQ!!g' -e 's!\.$!!g')
        MessagesOnQueue=$(echo $_line | awk ' { print $2 } ')
    
        if [ $MessagesOnQueue -ne 0 ] ; then
            # Perform the transfer
            MoveMessages $FromQueue $ToQueue
        else
            Log Info "No messages found on queue [$FromQueue]"
        fi

    done


fi

if [ "$FromQueue" ] ; then

    # Vaidate the passed in queues are valid
    if $( ! $ACTIVEMQ_ADMIN_SCRIPT dstat | grep "$FromQueue" >/dev/null 2>&1 ) ; then
        Log Error "FromQueue [$FromQueue] is not a valid queue"
    fi

    if $( ! $ACTIVEMQ_ADMIN_SCRIPT dstat | grep "$ToQueue" >/dev/null 2>&1 ) ; then
        Log Error "ToQueue [$ToQueue] is not a valid queue"
    fi

    MessagesOnQueue=$($ACTIVEMQ_ADMIN_SCRIPT dstat | awk -v FromQueue="^"$FromQueue"$" ' {if ($1 ~ FromQueue) print $2 } ')

    if [ "$MessagesOnQueue" -ne 0 ] ; then
        # Perform the transfer
        MoveMessages $FromQueue $ToQueue
    else
        Log Info "No messages found on queue [$FromQueue]"
    fi
fi

# Exit cleanly
exit 0
