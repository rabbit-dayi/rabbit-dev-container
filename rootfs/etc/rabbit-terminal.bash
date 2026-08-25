# Interactive terminal defaults for the development shell.
case "$-" in
    *i*) ;;
    *) return ;;
esac
[ -n "${RABBIT_TERMINAL_LOADED:-}" ] && return
RABBIT_TERMINAL_LOADED=1

HISTCONTROL=ignoreboth:erasedups
HISTSIZE=10000
HISTFILESIZE=20000
PROMPT_DIRTRIM=3
shopt -s histappend cmdhist checkwinsize

alias l='ls -CF --group-directories-first'
alias la='ls -A --group-directories-first'
alias ll='ls -alF --group-directories-first'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status --short --branch'
alias gd='git diff'
alias gl='git log --oneline --decorate -10'

if command -v batcat >/dev/null 2>&1; then
    alias bat='batcat --paging=never --style=plain'
fi

for fzf_script in \
    /usr/share/doc/fzf/examples/key-bindings.bash \
    /usr/share/fzf/key-bindings.bash; do
    if [ -r "$fzf_script" ]; then
        source "$fzf_script"
        break
    fi
done
export FZF_DEFAULT_OPTS="${FZF_DEFAULT_OPTS:---height 45% --layout=reverse --border}"

if [ -r /usr/lib/git-core/git-sh-prompt ]; then
    source /usr/lib/git-core/git-sh-prompt
    GIT_PS1_SHOWDIRTYSTATE=1
    GIT_PS1_SHOWSTASHSTATE=1
    GIT_PS1_SHOWUNTRACKEDFILES=1
    GIT_PS1_SHOWUPSTREAM=auto
    git_segment='\[\e[38;5;245m\]$(__git_ps1 " (%s)")\[\e[0m\]'
else
    git_segment=''
fi

PS1='\[\e]0;\u@\h: \w\a\]\[\e[1;38;5;39m\]\u@\h\[\e[0m\] \[\e[38;5;75m\]\w\[\e[0m\]'"${git_segment}"' \[\e[1;38;5;114m\]rabbit\[\e[0m\] \[\e[1;38;5;213m\]>\[\e[0m\] '
