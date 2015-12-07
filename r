#!/bin/bash

usage() {
bname=$1
cat << EOF
Usage:
    $bname exec  [-l LIST|-h HOST|-P PORT|-u USER|-p PASSWORD] [-q] [-s SCRIPT|COMMANDS]
    $bname push  [-l LIST|-h HOST|-P PORT|-u USER|-p PASSWORD] [-q] SRC... DST
    $bname shell [-l LIST|-d DESC|-h HOST|-P PORT|-u USER|-p PASSWORD]
EOF
}

help() {
    bname=$(basename $0)
    usage "$bname"
    echo -e "\nFor more information, run: $bname -h"
}

detailed_help() {
bname=$(basename $0)
cat << EOF
$(usage "$bname")

Examples:
    Execute one command:
        $ $bname exec -l servers.txt uptime

    Execute a list of commands:
        $ $bname exec -l servers.txt 'touch /tmp/flag; uptime'

    Execute a script:
        $ $bname exec -l servers.txt -s job.sh

    Push one file:
        $ $bname push -l servers.txt /etc/passwd /tmp/passwd

    Push multiple files:
        $ $bname push -l servers.txt /etc/passwd /etc/group /tmp

    Shell to each host in the list:
        $ $bname shell -l servers.txt

    Shell to one specific host in the list:
        $ $bname shell -l servers.txt -h 10.1.1.11

    Execute a script on one host in the list, pick by host name:
        $ $bname exec -l servers.txt -h 10.1.1.12 /tmp/special_script.sh

    Execute a script on one host in the list, pick by host description:
        $ $bname exec -l servers.txt -d dns1 /tmp/special_script.sh

    Execute a script on all hosts, suppress all output:
        $ $bname exec -l servers.txt -q /tmp/common_script.sh

    Execute a command, provide the login information manually:
        $ $bname exec -h 10.1.1.1 -P 22 -u admin -p "p@ssword" 'grep ERROR /var/log/message'

LIST file shall be formated like this, one host per line:
hostname:port:username:password

If the -l option is not provided, -h, -P, -u, -p are required, the
command then will work on one single host.

If both the -l and -h options are provided, the command will operate
on that host, login information is fetched from the LIST file.

If the -s option is provided, the COMMAND will be silently ignored.
EOF
}

parse_arguments() {
    while getopts "d:l:s:h:P:u:p:q" op
    do
        case "$op" in
            l)  server_list=$OPTARG ;;
            s)  script_file=$OPTARG ;;
            h)  host=$OPTARG ;;
            d)  desc=$OPTARG ;;
            P)  port=$OPTARG ;;
            u)  user=$OPTARG ;;
            p)  pass=$OPTARG ;;
            q)  quiet=1 ;;
            *)  ;;
        esac
    done

    # shift the processed options, assume that no
    # other options between these processed options
    shift $((OPTIND - 1))

    # file existence check
    if test -n "$server_list" && test ! -f "$server_list"; then
        echo "$server_list not exists" >&2
        return 1
    fi
    if test -n "$script_file" && test ! -f "$script_file"; then
        echo "$script_file not exists" >&2
        return 1
    fi

    # either server_list must be provided,
    # or all of -h, -P, -u, -p.
    if test -z "$server_list" && ! login_info_ok "$host" "$port" "$user" "$pass"; then
        echo "argument error" >&2
        help >&2
        return 1
    fi

    # explicitly pick a single host from the server list
    # this is convenient to access one host from many.
    # if user name is supplied, filter with user name.
    if test -n "$server_list" && test -n "$host" -o -n "$desc"; then
        if test -n "$desc"; then
            records=$(awk -F: '$1 == "'${desc}'"{print $0}' $server_list)
        elif test -n "$host"; then
            records=$(awk -F: '$2 == "'${host}'"{print $0}' $server_list)
        fi
        if test -n "$user"; then
            record=$(awk -F: '$4 == "'${user}'"{print $0; exit}' <<< "$records")
        else
            record=$(head -n1 <<< "$records")
        fi
        if test -z "$record"; then
            echo "no host record found for the given parameters" >&2
            return 1
        fi
        IFS=: read desc host port user pass <<< "$record"
        if ! login_info_ok "$host" "$port" "$user" "$pass"; then
            echo "bad login information" >&2
            return 1
        fi
        unset server_list   # it's now a single host operation
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
# $1: host
# $2: port
# $3: user
# $4: password
login_info_ok() {
    if ! test -n "$1" -a -n "$2" -a -n "$3" -a -n "$4"; then
        echo "empty value is not allowed for host, port, user, password" >&2
        return 1
    fi
    if ! grep -qE '^[1-9][0-9]*$' <<< "$2"; then
        echo "invalid port number" >&2
        return 1
    fi
    return 0
}

log() {
    echo "$*" >&2
    logger -t "[AUTO-SSH] " -p local0.info "$*"
}

# run sub-commands on the remote hosts, do it in a parallel manner
# by default; handle exec, push, shell commands; $1 shall be a
# function to actually perform the task for push, exec, shell
run_cmd() {
    doer=$1
    serial=$2
    tty=$3
    if test -n "$server_list"; then
        # bulk operation
        OLDIFS=$IFS
        IFS=:
        while read desc host port user pass
        do
            if ! login_info_ok "$host" "$port" "$user" "$pass"; then
                continue
            fi
            # serial mode is used by shell sub-command shell,
            # shell also needs a terminal as its stdin. since
            # the stdin of the while block is not a tty, we
            # need to restore it back to /dev/tty before shell.
            if test "$serial" = 1; then
                if test -n "$tty"; then
                    exec 3<"$tty"
                else
                    exec 3<&0
                fi
                $doer "$host" "$port" "$user" "$pass" 0<&3
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

# get a shell of the remote host
# arguments: host port user password
shell_one_host() {
    $RSHELL "$1" "$2" "$3" "$4"
    if test $? -eq 0; then
        log "ACTION=SHELL ; LAST_STATE=zero ; HOST=$1"
    else
        log "ACTION=SHELL ; LAST_STATE=non-zero ; HOST=$1"
        return 1
    fi
}

shell() {
    # shell sub-command shall run in serial mode
    run_cmd "shell_one_host" 1 /dev/tty
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

# show the help message
if test -z "$1"; then
    help
    exit
elif test "$1" = '-h'; then
    detailed_help
    exit
fi

cd $(dirname $(real_path $0))
sub_command=$1
shift
parse_arguments "$@" || exit

# handle quiet mode, no effect for 'shell' sub-command
if test "$quiet" = 1 -a "$sub_command" != 'shell'; then
    exec 1> /dev/null
    exec 2> /dev/null
fi

case "$sub_command" in
    exec) execute ;;
    push) push ;;
    shell) shell ;;
    *) help ;;
esac
