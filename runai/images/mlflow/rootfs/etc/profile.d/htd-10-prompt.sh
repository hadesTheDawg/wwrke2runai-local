# HTD Researcher prompt:   HTD ⚗ alice@team-a ~/src (main) ❯
[ -n "${BASH_VERSION:-}" ] && [ -n "${PS1:-}" ] || return 0

__htd_git() {
  local b
  b=$(git symbolic-ref --short HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null) || return
  printf ' \001\e[33m\002(%s)\001\e[0m\002' "$b"
}
__htd_status() {   # red prompt arrow after a failed command
  [ "$1" = 0 ] && printf '\001\e[38;5;208m\002❯' || printf '\001\e[31m\002❯'
}

PS1='$(__htd_status $?) \[\e[1;38;5;208m\]HTD\[\e[0m\] \[\e[35m\]⚗\[\e[0m\] '
PS1+='\[\e[1;36m\]${HTD_USER}\[\e[0m\]@\[\e[32m\]${HTD_PROJECT:-local}\[\e[0m\] '
PS1+='\[\e[1;34m\]\w\[\e[0m\]$(__htd_git)\n\[\e[38;5;208m\]❯\[\e[0m\] '
# terminal / tmux title
PS1='\[\e]0;HTD ${HTD_PROJECT:-local}/${HTD_WORKLOAD:-mlflow}: \w\a\]'"$PS1"
export PS1
