#!/bin/bash

PORT=1234
WORK=/tmp/server_work

mkdir -p $WORK

# find the IP address of this container 
IP=$(ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -1)

# show an error message to the client and on the server
fail() {
    echo "ERROR: $1"
    echo "ERROR: $1" >&2
}

# handle one client: the request is in $REQUEST, the reply is printed
handle() {
    grep Connection $LOG >&2          # "Connection received on <client ip> <port>"
}

# Main: runs forever
# once nc is listening, read its port back with ss
( sleep 1
  port=$(ss -ltnp | grep '"nc"' | awk '{print $4}' | cut -d: -f2)
  echo "The server is running at $IP, port=$port"
  echo "Listening on 0.0.0.0 $port" ) &

# One nc listener serves one client. Its files are named with a 1 or a 2:
start_listener() {
    rm -f $WORK/request.$1 $WORK/reply.$1 $WORK/ready.$1
    touch $WORK/reply.$1
    ( while [ ! -f $WORK/ready.$1 ]; do sleep 0.02; done; cat $WORK/reply.$1 ) | nc -4 -n -v -N -l $PORT > $WORK/request.$1 2> $WORK/conn.$1 &
    ncpid=$!
}

id=1
start_listener $id
while true; do
    REQUEST=$WORK/request.$id
    LOG=$WORK/conn.$id

    # wait for the request or for nc to stop
    while [ ! -s $REQUEST ]; do         
        kill -0 $ncpid 2>/dev/null
        if [ $? -ne 0 ]; then
            break
        fi
        sleep 0.01
    done

    if [ -s $REQUEST ]; then
        handle > $WORK/reply.$id
    fi

    # start the listener for the next client before letting this client go, so that there is never a moment when nobody is listening
    this=$ncpid
    next=$((3 - id))
    start_listener $next
    touch $WORK/ready.$id
    wait $this
    id=$next
done
