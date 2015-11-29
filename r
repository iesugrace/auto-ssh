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

parse_arguments() {
    while getopts "l:s:h:P:u:p:" op
    do
        case "$op" in
            l)  server_list=$OPTARG ;;
            s)  script_file=$OPTARG ;;
            h)  host=$OPTARG ;;
            P)  port=$OPTARG ;;
            u)  user=$OPTARG ;;
            p)  pass=$OPTARG ;;
            *)  ;;
        esac
    done

    # shift the processed options, assume that no
    # other options between these processed options
    shift $((OPTIND - 1))

    # either server_list must be provided,
    # or all of -h, -P, -u, -p.
    if test -z "$server_list" && ! login_info_ok "$host" "$port" "$user" "$pass"; then
        echo "argument error" >&2
        help >&2
        return 1
    fi

    # store the remaining arguments
    unset ARGS
    i=1
    for a in "$@"
    do
        ARGS[$i]=$a
        i=$((i + 1))
    done

    return 0
}

# check host, port, user name, password
login_info_ok() {
    test -n "$1" -a -n "$2" -a -n "$3" -a -n "$4"
}

log() {
    echo "$*" >&2
    # logger ...
}

# run sub-commands on the remote hosts, do it in a parallel manner
# by default; handle exec, push, shell commands; $1 shall be a
# function to actually perform the task for push, exec, shell
run_cmd() {
    doer=$1
    serial=$2
    if test -n "$server_list"; then
        # bulk operation
        OLDIFS=$IFS
        IFS=:
        while read host port user pass
        do
            if ! login_info_ok "$host" "$port" "$user" "$pass"; then
                continue
            fi
            if test "$serial" = 1; then
                $doer "$host" "$port" "$user" "$pass"
            else
                $doer "$host" "$port" "$user" "$pass" &
            fi
        done <<< "$(grep -v ^# $server_list)"
        wait
        IFS=$OLDIFS
    else
        # single host operation
        $doer "$host" "$port" "$user" "$pass"
    fi
}

# execute command on one host,
# upload script if required
# arguments: host port user password
execute_one_host() {
    if test -n "$script_file"; then
        dst="$(mktemp -u)_$(date +%s)"
        $RPUSH "$1" "$2" "$3" "$4" "$script_file" "$dst"
        if test $? -eq 0; then
            log "ACTION=PUSH ; STATE=OK ; SRC=$script_file ; DST=${1}:$dst"
        else
            log "ACTION=PUSH ; STATE=FAILED ; SRC=$script_file ; DST=${1}:$dst"
            return 1
        fi
        COMMAND_LIST="${dst}; rm -f $dst"
    else
        COMMAND_LIST=${ARGS[1]}
    fi
    $REXEC "$1" "$2" "$3" "$4" "$COMMAND_LIST"
    if test $? -eq 0; then
        log "ACTION=EXEC ; STATE=OK ; HOST=${1} ; CMD=$COMMAND_LIST"
    else
        log "ACTION=EXEC ; STATE=FAILED ; HOST=${1} ; CMD=$COMMAND_LIST"
    fi
}

# execute commands on the remote host
execute() {
    run_cmd "execute_one_host"
}

# push file(s) to the remote host
# arguments: host port user password
push_one_host() {
    len=${#ARGS[@]}
    dst=${ARGS[$len]}
    unset ARGS[$len]
    $RPUSH "$1" "$2" "$3" "$4" "${ARGS[@]}" "$dst"
    if test $? -eq 0; then
        log "ACTION=PUSH ; STATE=OK ; SRC=${ARGS[*]} ; DST=${1}:$dst"
    else
        log "ACTION=PUSH ; STATE=FAILED ; SRC=${ARGS[*]} ; DST=${1}:$dst"
        return 1
    fi
}

push() {
    run_cmd "push_one_host"
}

shell() {
    :
}

real_path() {
    if test -L $1; then
        readlink "$1"
    else
        echo "$1"
    fi
}

# plumbing commands
REXEC='./r-exec'
RPUSH='./r-push'
RSHELL='./r-shell'

cd $(dirname $(real_path $0))
sub_command=$1
shift
parse_arguments "$@" || exit
case "$sub_command" in
    exec) execute ;;
    push) push ;;
    shell) shell ;;
    *) help ;;
esac
