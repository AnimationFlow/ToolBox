# /home/<user>/.bashrc


###########
# WARNING #
###########


# Do NOT simply overwrite your entire .bashrc with this !
# find very similar section, comment out the old one and add these :


##########################
# Cool Prompt for Ubuntu #
##########################

# \n
# <user> @ <host> : <pwd>\n
#  --> |

if [ "$color_prompt" = yes ]; then
    PS1='${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\n\u @ \h\[\033[00m\] : \[\033[01;34m\]\w\[\033[00m\]\n --> '
else
    PS1='${debian_chroot:+($debian_chroot)}\n\u @ \h : \w\n --> '
fi
unset color_prompt force_color_prompt


####################
# podman shortcuts #
####################

alias pc='podman-compose'
alias pps='pc ps'       # processes
alias pcu='pc up -d'    # up detached
alias pcd='pc down'     # shut down
alias pcr='pcd && pcu'  # restart
alias pl='pc logs'      # logs
alias plf='pc logs -f'  # logs, follow (streaming)
alias prl='pcr && pl'   # restart and show logs
alias prlf='pcr && plf' # restart and show logs, follow


####################
# docker shortcuts #
####################

alias dc='docker-compose'
alias dps='dc ps'       # processes
alias dcu='dc up -d'    # up detached
alias dcd='dc down'     # shut down
alias dcr='dcd && dcu'  # restart
alias dl='dc logs'      # logs
alias dlf='dc logs -f'  # logs, follow (streaming)
alias drl='dcr && dl'   # restart and show logs
alias drlf='dcr && dlf' # restart and show logs, follow


##################
# bash shortcuts #
##################

alias c='clear'
alias h='history'
alias lh='ls -lah'
