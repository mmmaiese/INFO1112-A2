#!/bin/bash

PORT=1234
WORK=/tmp/server_work
LOG=$WORK/conn.log
REQUEST=$WORK/request.txt
REPLY=$WORK/reply.txt

mkdir -p $WORK

# find the IP address of this container
IP=$(ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -1)

# once nc is listening, read its port back with ss
( sleep 1
  port=$(ss -ltnp | grep '"nc"' | awk '{n=split($4,a,":"); print a[n]; exit}')
  echo "The server is running at $IP, port=$port"
  echo "Listening on 0.0.0.0 $port" ) &

# handle one client: the request is in $REQUEST, the reply is printed
handle() {
  grep Connection $LOG >&2 
}

# one trip round the loop serves one client: nc saves the request in $REQUEST and, once the
# file $WORK/reply.ready exists, sends the contents of $REPLY back on the same connection
while true; do
    rm -f $REQUEST $REPLY $WORK/reply.ready
    touch $REPLY

    ( while [ ! -f $WORK/reply.ready ]; do sleep 0.1; done; cat $REPLY ) | nc -4 -n -v -N -l $PORT > $REQUEST 2> $LOG &
    ncpid=$!

    # wait until the client has sent its request (or nc has stopped)
    while [ ! -s $REQUEST ]; do
        kill -0 $ncpid 2>/dev/null
        if [ $? -ne 0 ]; then
            break
        fi
        sleep 0.1
    done

    if [ -s $REQUEST ]; then
        handle > $REPLY
    fi
    touch $WORK/reply.ready         # now the reply is sent and the connection closes
    wait $ncpid
done
