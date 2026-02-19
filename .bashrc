# /home/<user>/.bashrc


###########
# WARNING #
###########


# Do NOT simply overwrite your entire .bashrc with this !
# find very similar section, comment out the old one and add these :


###############
# Cool Prompt #
###############

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
alias pu='pc up -d'     # up detached
alias pd='pc down'      # shut down
alias pr='pd && pu'     # restart
alias pl='pc logs'      # logs
alias plf='pc logs -f'  # logs, follow (streaming)
alias prl='pr && pl'    # restart and show logs
alias prlf='pr && plf'  # restart and show logs, follow


####################
# docker shortcuts #
####################

alias dc='docker-compose'
alias dps='dc ps'       # processes
alias du='dc up -d'     # up detached
alias dd='dc down'      # shut down
alias dr='dd && du'     # restart
alias dl='dc logs'      # logs
alias dlf='dc logs -f'  # logs, follow (streaming)
alias drl='dr && dl'    # restart and show logs
alias drlf='dr && dlf'  # restart and show logs, follow
