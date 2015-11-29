#!/bin/bash

help() {
    cat << EOF
Usage: $(basename $0) server-list cmd
       $(basename $0) server-list -f script
EOF
}

argparse() {
    if test $# -eq 2; then
        server_list=$1
        cmd=$2
    elif test $# -eq 3; then
        server_list=$1
        if test "$2" = "-f"; then
            script=$3
        else
            help >&2
            exit 1
        fi
    else
        help >&2
        exit 1
    fi
}

# upload script to the remote host
upload_file() {
    local user pass host port src dst
    user=$1
    pass=$2
    host=$3
    port=$4
    src=$5
    dst=$6
    $SCP "$user" "$pass" "$host" "$port" "$src" "$dst"
}

# run a command on the remote server
run_cmd() {
    local user pass host port cmd
    user=$1
    pass=$2
    host=$3
    port=$4
    cmd=$5
    $SSH "$user" "$pass" "$host" "$port" "$cmd"
}

# upload a script to remote, then run it remotely
run_script() {
    local user pass host port script
    user=$1
    pass=$2
    host=$3
    port=$4
    script=$5
    dst=/tmp/$(basename $script)
    upload_file "$user" "$pass" "$host" "$port" "$script" "$dst"
    run_cmd "$user" "$pass" "$host" "$port" "$dst; rm -f $dst"
}

real_path() {
    if test -L $1; then
        readlink "$1"
    else
        echo "$1"
    fi
}

port=22
user=joshua
SCP=./scp.expect
SSH=./ssh.expect

# start from here
cd $(dirname $(real_path $0))
argparse "$@"
while read host pass
do
    echo "working on $host" >&2
    if test -n "$script"; then
        run_script "$user" "$pass" "$host" "$port" "$script"
    else
        run_cmd "$user" "$pass" "$host" "$port" "$cmd"
    fi
done < ${server_list}
