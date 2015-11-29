#!/bin/bash

help() {
    cat << EOF
Usage:
$(basename $0) exec  -l SERVERS-LIST-FILE COMMAND-LIST-STRING
$(basename $0) exec  -l SERVERS-LIST-FILE -s SCRIPT-FILE
$(basename $0) push  -l SERVERS-LIST-FILE SRC... DST
$(basename $0) shell -l SERVERS-LIST-FILE
$(basename $0) exec  -h 10.1.1.1 -P 7722 -u admin -p "p@ssword" COMMAND-LIST-STRING
$(basename $0) exec  -h 10.1.1.1 -P 7722 -u admin -p "p@ssword" -s SCRIPT-FILE
$(basename $0) push  -h 10.1.1.1 -P 7722 -u admin -p "p@ssword" SRC... DST
$(basename $0) shell -h 10.1.1.1 -P 7722 -u admin -p "p@ssword" SERVERS-LIST-FILE

SERVERS-LIST-FILE shall be formated like this, one host per line:
hostname:port:username:password

If the -l option is not provided, -h, -P, -u, -p are required,
command works on one single host.

If the -s option is provided, the COMMAND-LIST-STRING will be
silently ignored.
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

cd $(dirname $(real_path $0))
sub_command=$1
shift
case "$sub_command" in
    exec) execute "$@" ;;
    push) push "$@" ;;
    shell) shell "$@" ;;
    *) help ;;
esac
