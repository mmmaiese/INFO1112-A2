#!/bin/bash

PORT=1234
WORK=/tmp/server_work
ASSIGNMENT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"

mkdir -p $WORK

# find the IP address of this container 
IP=$(ifconfig | grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$' | grep -v '^127\.' | head -1)

# show an error message to the client and on the server
show_error() {
    echo "ERROR: $1"
    echo "ERROR: $1" >&2
}

# Downloads assignment details, extracts the required information and returns it as JSON.
handle_assignment() {
    html=$(curl -s -f -L -m 20 "$ASSIGNMENT_URL")
    if [ $? -ne 0 ]; then
        show_error "could not download the unit outline page"
        return
    fi

    # the page text without tags, starting at the last "Assignment N". Puts the whole page on one line, so sed can work across the line breaks.
    info=$(echo "$html" | tr '\n' ' ' | sed 's/<[^>]*>/ /g; s/&nbsp;/ /g; s/  */ /g' | sed -E 's/.*Assignment ([0-9]+ )/\1/')
    number=$(echo "$info" | grep -oE '^[0-9]+')
    topic=$(echo "$info" | sed -n 's/^[0-9]* [^-]*- *\([A-Za-z]*\).*/\1/p')
    points=$(echo "$info" | grep -oE '[0-9]+%' | head -1 | sed 's/%//')
    due=$(echo "$info" | grep -oE 'Due date *: *[0-9]+ [A-Za-z]+ [0-9]+ at [0-9:]+' | head -1 | sed -E 's/Due date *: *//; s/ at / /')
   
    if [ -z "$number" ] || [ -z "$topic" ] || [ -z "$points" ] || [ -z "$due" ]; then
        show_error "could not find the assignment details on the page"
        return
    fi

    # html -> text, then show this assignment's rows on the server (like Fig 7)
    echo "$html" | html2text | grep -A2 "Assignment $number" >&2

    # build assignment.json with jq (the values come from the variables above)
    jq -n --arg title "Assignment $number" --arg topic "$topic" --arg due "$due" --argjson points "$points" \
        '{title: $title, topic: $topic, due_date: $due, points: $points}' > assignment.json
    cat assignment.json
}

# handle one client: the request is in $REQUEST, the reply is printed
handle_request() {
    grep Connection $LOG >&2          # "Connection received on <client ip> <port>"
    line=$(head -1 $REQUEST)
    cmd=$(echo "$line" | cut -d' ' -f1)
    arg=$(echo "$line" | cut -s -d' ' -f2-)

    case $cmd in
        assignment) handle_assignment ;;      # (the brief's example has three s)
        *)          show_error "unknown request '$cmd'" ;;
    esac
}

# Main: runs forever
# once nc is listening, read its port back with ss
( sleep 1
  port=$(ss -ltnp | grep '"nc"' | awk '{print $4}' | cut -d: -f2)
  echo "The server is running at $IP, port=$port"
  echo "Listening on 0.0.0.0 $port" ) &

# One nc listener serves one client.
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
        handle_request > $WORK/reply.$id
    fi

    # Switches between listeners 1 and 2 to handle consecutive client requests.
    this=$ncpid
    next=$((3 - id))
    start_listener $next
    touch $WORK/ready.$id
    wait $this
    id=$next
done
