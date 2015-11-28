#!/bin/bash

# Ubuntu 15.04 URN: urn:publicid:IDN+emulab.net+image+emulab-ops:UBUNTU15-04-64-STD

cd $(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

function prompt()
{
    [[ "$1" != '' ]]
    read -p '> ' prompt_ret
    echo $prompt_ret
}

CONF_FILE="./scale.cfg"
NODE_PATH="./node"
NODE_NODE_SCRIPT='./node/node.bash'

NODES=()
NR_NODES=0
SERVER=''
FORWARDER=''
SIZE=0

# parse config file
while read line; do
    opt=$(echo $line | awk '{print $1}')
    arg=$(echo $line | awk '{print $2 " " $3 " " $4}')

    case $opt in
        ("NODE")
            NODES+=("$arg");;
        ("SERVER")
            arggg=$(echo $arg | awk '{print $1}')
            echo $arggg:
            SERVER=$arggg;;
        ("FORWARDER")
            arggg=$(echo $arg | awk '{print $1}')
            echo $arggg:
            FORWARDER=$arggg;;
        ("SIZE")
            SIZE=$arg;;
    esac
done < $CONF_FILE
NR_NODES=${#NODES[@]}

# main loop
while true; do

    line=($(prompt))
    cmd=${line[0]}
    args=(${line[@]:1})

    case $cmd in

        ("accept")
            echo "enter 'yes' to add a node to the list of known hosts"
            for node in "${NODES[@]}"; do
                ssh ${node} 
                #ssh "${node}" "echo 'accepted connection: $node'"
            done
            ;;
        ("install")
            # compress local sources; transfer sources to each node; nodes install
            tar -zcvf node.tar.gz $NODE_PATH
            for node in ${NODES[@]}; do
                bash -c "
                    echo 'put node.tar.gz' | sftp $node;
                    ssh $node 'tar xf node.tar.gz; bash $NODE_NODE_SCRIPT install';
                " &
            done
            wait
            ;;
        ("install-vm")
            # compress local sources; transfer sources to each node; nodes install
            tar -zcvf node-vm.tar.gz $NODE_PATH
            for node in "${NODES[@]}"; do
                port_number=$(echo $node | awk '{print $2}')
                host=$(echo $node | awk '{print $3}')
                #echo "$port_number"
                #echo "$host"
                scp -P ${port_number} node-vm.tar.gz ${host}:
                ssh -p ${port_number} ${host} 'tar xf node-vm.tar.gz'
            done
            wait
            # Install ejabberd only at server node
            echo "Downloading ejabberd"
            ssh $SERVER 'wget https://www.process-one.net/downloads/downloads-action.php?file=/ejabberd/15.11/ejabberd_15.11-0_amd64.deb -O ejabberd_15.11-0_amd64.deb'
            echo "installing ejabberd"
            ssh $SERVER 'sudo dpkg -i ejabberd_15.11-0_amd64.deb'
            echo "copy ejabberd config file from local to server"
            ls ./node/config/ejabberd.yml
            pwd
            echo $SERVER
            echo ${SERVER}
            echo $SERVER:
            echo ${SERVER}:
            scp ./node/config/ejabberd.yml ${SERVER}:
            echo "copy ejabberd config file from download folder to config folder"
            ssh $SERVER 'sudo cp ejabberd.yml /opt/ejabberd-15.11/conf/ejabberd.yml' 
            echo "Restarting ejabberd"
            ssh $SERVER 'sudo /opt/ejabberd-15.11/bin/ejabberdctl start'
            sleep 60
            for i in $(seq 0 $((${#NODES[@]}-1))); do
                ssh $SERVER "sudo /opt/ejabberd-15.11/bin/ejabberdctl register node${i} ejabberd password"
            done
            ssh $SERVER 'sudo /opt/ejabberd-15.11/bin/ejabberdctl srg_create ipop_vpn ejabberd ipop_vpn ipop_vpn ipop_vpn'
            ssh $SERVER 'sudo /opt/ejabberd-15.11/bin/ejabberdctl srg_user_add @all@ ejabberd ipop_vpn ejabberd'
            wait
       
            ;;
        ("init")
            if [ "${args[0]}" != "" ]; then
                SIZE=${args[0]}
                sed -i "s/SIZE.*/SIZE $SIZE/g" $CONF_FILE
            fi

            # initialize containers (vnodes)
            for i in $(seq 0 $(($NR_NODES-1))); do
                min=$(($i * ($SIZE / $NR_NODES)))
                max=$(((($i+1) * ($SIZE / $NR_NODES)) - 1))

                ssh ${NODES[$i]} "bash $NODE_NODE_SCRIPT init-containers $min $max" &
            done
            wait

            # initialize ejabberd
            ssh $SERVER "bash $NODE_NODE_SCRIPT init-server $SIZE"

            ;;
        
        #("init-vm")
        ("restart")
            ssh $SERVER "bash $NODE_NODE_SCRIPT restart-server"
            ;;
        ("exit")
            # remove containers
            for node in ${NODES[@]}; do
                 ssh $node "bash $NODE_NODE_SCRIPT exit-containers" &
            done
            wait

            # remove ejabberd
            ssh $SERVER "bash $NODE_NODE_SCRIPT exit-server"
            ;;
        ("source")
            # compress local sources; transfer sources to each node; nodes update souces of each vnode
            tar -zcvf node.tar.gz $NODE_PATH
            for node in ${NODES[@]}; do
                bash -c "
                    echo 'put node.tar.gz' | sftp $node;
                    ssh $node 'tar xf node.tar.gz; bash $NODE_NODE_SCRIPT source';
                " &
            done
            wait
            ;;
        ("source-vm")
            # compress local sources; transfer sources to each node; nodes install
            tar -zcvf node-vm.tar.gz $NODE_PATH
            for node in "${NODES[@]}"; do
                port_number=$(echo $node | awk '{print $2}')
                host=$(echo $node | awk '{print $3}')
                #echo "$port_number"
                #echo "$host"
                scp -P ${port_number} node-vm.tar.gz ${host}:
                ssh -p ${port_number} ${host} 'tar xf node-vm.tar.gz'
            done
            wait
            ;;
        ("config")
            # obtain ipv4 address of ejabberd server
            server_node_ethd=$(ssh $SERVER ifconfig | grep eth | awk '{print $1}' | head -n 1)
            server_node_ipv4=$(ssh $SERVER ifconfig $server_node_ethd | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')

            # obtain ipv4 address/port of forwarder
            forwarder_node_ethd=$(ssh $FORWARDER ifconfig | grep eth | awk '{print $1}' | head -n 1)
            forwarder_node_ipv4=$(ssh $FORWARDER ifconfig $forwarder_node_ethd | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
            forwarder_node_port=51234

            # vnodes create IPOP config files
            for node in ${NODES[@]}; do
                # prepare arguments
                xmpp_host=$server_node_ipv4
                stun="$server_node_ipv4:3478"
                turn="$server_node_ipv4:19302"
                central_visualizer='true'
                central_visualizer_ipv4=$forwarder_node_ipv4
                central_visualizer_port=$forwarder_node_port

                ssh $node "bash $NODE_NODE_SCRIPT config $xmpp_host $stun $turn $central_visualizer $central_visualizer_ipv4 $central_visualizer_port ${args[@]}" &
            done
            wait
            ;;
        ("config-vm")
            # obtain ipv4 address of ejabberd server
            #echo ${args[0]}
            #echo ${args[1]}
            #echo ${args[2]}
            #echo ${args[3]}
            #echo ${args[4]}
            server_node_ethd=$(ssh $SERVER ifconfig | grep eth | awk '{print $1}' | head -n 1)
            server_node_ipv4=$(ssh $SERVER ifconfig $server_node_ethd | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
            echo $server_node_ethd
            echo $server_node_ipv4

            # obtain ipv4 address/port of forwarder
            forwarder_node_ethd=$(ssh $FORWARDER ifconfig | grep eth | awk '{print $1}' | head -n 1)
            forwarder_node_ipv4=$(ssh $FORWARDER ifconfig $forwarder_node_ethd | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
            forwarder_node_port=51234
            echo $forwarder_node_ethd
            echo $forwarder_node_ipv4

            # create config file for each node
            #for i in $(seq $min $max); do
            for i in $(seq 0 $((${#NODES[@]}-1))); do
            #for ((i=0, i<$#NODES[@]; i++)); do
                # parse and prepare arguments
                xmpp_username="node$i@ejabberd"
                xmpp_password="password"
                xmpp_host=$server_node_ipv4
                stun=$server_node_ipv4
                ipv4='172.31.'$(($i / 256))'.'$(($i % 256))
                ipv4_mask=16
                central_visualizer='true'
                central_visualizer_ipv4=$forwarder_node_ipv4
                central_visualizer_port=$forwarder_node_port
                #num_successors=$1
                num_successors=${args[0]}
                #num_chords=$2
                num_chords=${args[1]}
                #num_on_demand=${3}
                num_on_demand=${args[2]}
                #num_inbound=${4}
                num_inbound=${args[3]}

                #ttl_link_initial=${5}
                ttl_link_initial=${args[4]}
                #ttl_link_pulse=${6}
                ttl_link_pulse=${args[5]}

                #ttl_chord=${7}
                ttl_chord=${args[6]}
                #ttl_on_demand=${8}
                ttl_on_demand=${args[7]}

                #threshold_on_demand=${9}
                threshold_on_demand=${args[8]}

                #echo ${NODES[$i]}
                #echo $num_successors
                #echo $num_chords
                #echo $num_on_demand
                #echo $num_inbound
                #echo $ttl_link_initial
                ssh ${NODES[$i]} "bash ./node/ipop/ipop.bash config $xmpp_username $xmpp_password $xmpp_host $stun '$turn' $ipv4 $ipv4_mask $central_visualizer $central_visualizer_ipv4 $central_visualizer_port $num_successors $num_chords $num_on_demand $num_inbound $ttl_link_initial $ttl_link_pulse $ttl_chord $ttl_on_demand $threshold_on_demand" &
            done
            wait

            ;;
        ("forward")
            # obtain ipv4 address/port of forwarder
            forwarder_node_ethd=$(ssh $FORWARDER ifconfig | grep eth | awk '{print $1}' | head -n 1)
            forwarder_node_ipv4=$(ssh $FORWARDER ifconfig $forwarder_node_ethd | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
            forwarder_node_port=51234
            forward_port=${args[0]}

            ssh $FORWARDER "bash $NODE_NODE_SCRIPT forward $forwarder_node_ipv4 $forwarder_node_port $forward_port &" &

            echo "connect visualizer to $forwarder_node_ipv4 $forward_port"
            ;;
        ("forward-vm")
            # obtain ipv4 address/port of forwarder
            forwarder_node_ethd=$(ssh $FORWARDER ifconfig | grep eth | awk '{print $1}' | head -n 1)
            forwarder_node_ipv4=$(ssh $FORWARDER ifconfig $forwarder_node_ethd | grep "inet addr" | awk -F: '{print $2}' | awk '{print $1}')
            forwarder_node_port=51234
            forward_port=${args[0]}

            scp ./node/node.bash $FORWARDER:
            scp ./node/cv_forwarder.py $FORWARDER:
            echo $forwarder_node_ipv4
            echo $forwarder_node_port
            echo $forward_port

            ssh $FORWARDER "bash node.bash forward $forwarder_node_ipv4 $forwarder_node_port $forward_port &" &

            echo "connect visualizer to $forwarder_node_ipv4 $forward_port"
            ;;
        ("run")
            # check if 'all' is present
            for i in ${args[@]}; do
                if [ "$i" == 'all' ]; then
                    args=($(seq 0 $(($SIZE-1))))
                fi
            done

            # create list of vnodes for each node
            node_list=()
            for i in ${args[@]}; do
                index=$(($i / ($SIZE / $NR_NODES)))
                node_list[$index]="${node_list[$index]} $i"
            done

            # nodes run list of vnodes
            for i in $(seq 0 $(($NR_NODES - 1))); do
                ssh ${NODES[$i]} "bash $NODE_NODE_SCRIPT run '${node_list[$i]}' &" &
            done
            ;;
        ("run-vm")
            for i in $(seq 0 $(($NR_NODES - 1))); do
                ssh ${NODES[$i]} "bash ./node/ipop/ipop.bash run &" &
            done
            ;;
        ("kill")
            # check if 'all' is present
            for i in ${args[@]}; do
                if [ "$i" == 'all' ]; then
                    args=($(seq 0 $(($SIZE-1))))
                fi
            done

            # create list of vnodes for each node
            node_list=()
            for i in ${args[@]}; do
                index=$(($i / ($SIZE / $NR_NODES)))
                node_list[$index]="${node_list[$index]} $i"
            done

            # nodes kill list of vnodes
            for i in $(seq 0 $(($NR_NODES - 1))); do
                ssh ${NODES[$i]} "bash $NODE_NODE_SCRIPT kill '${node_list[$i]}' &" &
            done
            ;;
        ("kill-vm")
            for i in $(seq 0 $(($NR_NODES - 1))); do
                ssh ${NODES[$i]} "bash ./node/ipop/ipop.bash kill &" &
            done
            ;;
        
        ("quit")
            exit 0
            ;;
        (*)
            echo 'usage:'
            echo '  platform management:'
            echo '    accept             : manually enable connections'
            echo '    install            : install/prepare resources'
            echo '    install-vm         : install/prepare resources'
            echo '    init    [size]     : initialize platform'
            echo '    restart            : restart services'
            echo '    exit               : clear platform'
            echo '    source             : upload sources'
            echo '    source-vm          : upload sources'
            echo '    config  <args>     : create IPOP config file'
            echo '    config-vm  <args>  : create IPOP config file'
            echo '    forward <port>     : run forwarder in background'
            echo '    forward-vm <port>  : run forwarder in background'
            echo ''
            echo '  IPOP network simulation:'
            echo '    run     [list|all] : run list|all nodes'
            echo '    run-vm  [list|all] : run list|all nodes'
            echo '    kill    [list|all] : kill list|all nodes'
            echo '    kill-vm [list|all] : kill list|all nodes'
            echo ''
            echo '  utility:'
            echo '    quit               : quit program'
            ;;

    esac

done

