#!/bin/bash

PORT=1234
WORK=/tmp/server_work
ASSIGNMENT_URL="https://www.sydney.edu.au/units/INFO1112/2026-S2C-ND-CC"
POPULATION_URL="https://dbr.abs.gov.au/processedData/csv/STE_1.csv"
POI_URL="https://maps.six.nsw.gov.au/arcgis/rest/services/public/NSW_POI/MapServer/0/query"

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


# Download NSW population data, extract yearly figures and generate a population graph.
handle_population() {
    curl -s -f -L -m 30 -o $WORK/STE_1.csv "$POPULATION_URL"
    if [ $? -ne 0 ]; then
        show_error "could not download the population csv"
        return
    fi

    # line 1 of the csv holds the years, the line starting ERP_P_20 holds the populations.
    # Columns 4 onwards are the years: take each column, and keep it if it has a population.
    header=$(head -1 $WORK/STE_1.csv | sed 's/\r//')
    row=$(grep '^ERP_P_20' $WORK/STE_1.csv | sed 's/\r//')
    commas=$(echo "$header" | grep -o ',' | wc -l)
    last=$((commas + 1))                        # number of columns

    rm -f $WORK/population.csv
    col=4
    while [ $col -le $last ]; do
        year=$(echo "$header" | cut -d, -f$col)
        pop=$(echo "$row" | cut -d, -f$col)
        if [ -n "$pop" ]; then
            echo "$year,$pop" >> $WORK/population.csv
        fi
        col=$((col + 1))
    done
    if [ ! -s $WORK/population.csv ]; then
        show_error "no population data found in the csv"
        return
    fi
    latest=$(grep '^2025,' "$WORK/population.csv" | sed 's/,/ /')
    echo "Latest NSW population: $latest" >&2

    # I acknowledge that I used Claude AI to write python code for the plotting.
    # the plot (AI python code)
    cat > $WORK/plot.py << 'PYEOF'
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
years, pops = [], []
for line in open(sys.argv[1]):
    y, p = line.strip().split(",")
    years.append(int(y)); pops.append(int(p))
plt.plot(years, pops, marker="o")
plt.xlabel("Year"); plt.ylabel("Population")
plt.xticks(years); plt.ticklabel_format(axis="y", style="plain")
plt.savefig(sys.argv[2])
PYEOF
    python3 $WORK/plot.py $WORK/population.csv population.png 2>/dev/null
    if [ $? -ne 0 ]; then
        show_error "could not draw the plot"
        return
    fi
    cat population.png
}


# Extract nearby POI names, check the JSON is valid and send it to the client.
handle_poi() {
    distance=$(echo "$1" | grep -oE 'distance=[0-9]+' | cut -d= -f2)
    if [ -z "$distance" ]; then
        distance=1000
    fi
    place=$(echo "$1" | sed 's/distance=[0-9]*//; s/^ *//; s/ *$//')
    if [ -z "$place" ]; then
        show_error "usage: poi <name or lat,lon> distance=<metres>"
        return
    fi

    # Get the latitude and longitude of the POI
    if echo "$place" | grep -qE '^-?[0-9.]+,-?[0-9.]+$'; then
        latitude=$(echo "$place" | cut -d, -f1)
        longitude=$(echo "$place" | cut -d, -f2)
    else
        name=$(echo "$place" | tr 'a-z' 'A-Z')
        response=$(curl -s -f -G -m 20 "$POI_URL" \
                         --data-urlencode "where=poiname like '%$name%'" \
                         --data-urlencode "returnGeometry=true" \
                         --data-urlencode "outSR=4326" \
                         --data-urlencode "resultRecordCount=1" \
                         --data-urlencode "f=json")
        if [ $? -ne 0 ]; then
            show_error "could not connect to the NSW POI service"
            return
        fi
        longitude=$(echo "$response" | jq -r '.features[0].geometry.x // empty' 2>/dev/null)
        latitude=$(echo "$response" | jq -r '.features[0].geometry.y // empty' 2>/dev/null)
    fi
    if [ -z "$latitude" ] || [ -z "$longitude" ]; then
        show_error "'$place' was not found by the NSW POI service"
        return
    fi

    # Get every POI within the distance of that point
    response=$(curl -s -f -G -m 20 "$POI_URL" \
                     --data-urlencode "geometry=$longitude,$latitude" \
                     --data-urlencode "geometryType=esriGeometryPoint" \
                     --data-urlencode "inSR=4326" \
                     --data-urlencode "distance=$distance" \
                     --data-urlencode "units=esriSRUnit_Meter" \
                     --data-urlencode "where=1=1" \
                     --data-urlencode "outFields=poiname" \
                     --data-urlencode "returnGeometry=false" \
                     --data-urlencode "f=json")
    if [ $? -ne 0 ]; then
        show_error "could not connect to the NSW POI service"
        return
    fi

    # Keep only the POI names, as a json array (poi.json), and send it
    echo "$response" | jq '[.features[]?.attributes.poiname]' > poi.json 2>/dev/null
    if [ ! -s poi.json ]; then
        show_error "the NSW POI service gave an invalid response"
        return
    fi
    cat poi.json
}


# When busy reject anyone who connects while a request is running
start_busy() {
    touch $WORK/busy
    while [ -f $WORK/busy ]; do
        echo "ERROR: server is busy with another request; request rejected" | nc -4 -n -N -l $IP $PORT > /dev/null 2>&1
    done > /dev/null 2>&1 &
    sleep 0.1
}

stop_busy() {
    rm -f $WORK/busy
    pkill -f "nc -4 -n -N -l $IP"  
}


# handle one client: the request is in $REQUEST, the reply is printed
handle_request() {
    grep Connection $LOG >&2          # "Connection received on <client ip> <port>"
    line=$(head -1 $REQUEST)
    cmd=$(echo "$line" | cut -d' ' -f1)
    arg=$(echo "$line" | cut -s -d' ' -f2-)

    start_busy
    case $cmd in
        assignment) handle_assignment ;;
        population) handle_population ;;
        poi) handle_poi "$arg" ;;
        slow) sleep 10; echo "slow request finished" ;;
        *) show_error "unknown request '$cmd'" ;;
    esac
    stop_busy
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
