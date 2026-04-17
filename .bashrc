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


##################
# bash shortcuts #
##################

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias lh='ls -alh'
alias c='clear'
alias h='history'
alias v='python3 -m venv .venv && source .venv/bin/activate'


####################
# podman shortcuts #
####################

alias pc='podman-compose'
alias pps='pc ps'           # processes
alias pce='pc exec'         # in container execute command
alias pcw='pc watch'        # experimental hot-reload that rebuilds on file changes automatically
alias pcb='pc up --build'   # builds without starting
alias pcu='pc up -d'        # up detached
alias pcd='pc down'         # shut down
alias pcr='pcd && pcu'      # restart
alias pcl='pc logs'         # logs
alias plf='pc logs -f'      # logs, follow (streaming)
alias prl='pcr && pl'       # restart and show logs
alias prf='pcr && plf'      # restart and show logs, follow


####################
# docker shortcuts #
####################

alias dc='docker-compose'
alias dps='dc ps'           # processes
alias dce='dc exec'         # in container execute command
alias dcw='dc watch'        # experimental hot-reload that rebuilds on file changes automatically
alias dcb='dc up --build'   # builds without starting
alias dcu='dc up -d'        # up detached
alias dcd='dc down'         # shut down
alias dcr='dcd && dcu'      # restart
alias dcl='dc logs'         # logs
alias dlf='dc logs -f'      # logs, follow (streaming)
alias drl='dcr && dl'       # restart and show logs
alias drf='dcr && dlf'      # restart and show logs, follow
