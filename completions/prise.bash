# Bash completion for prise

_prise_sessions() {
    prise session list 2>/dev/null
}

_prise_pty_ids() {
    prise pty list 2>/dev/null | grep -oE '^[0-9]+'
}

_prise() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    case "${COMP_WORDS[1]}" in
        session)
            case "${COMP_WORDS[2]}" in
                attach|delete)
                    COMPREPLY=($(compgen -W "$(_prise_sessions)" -- "$cur"))
                    return
                    ;;
                rename)
                    COMPREPLY=($(compgen -W "$(_prise_sessions)" -- "$cur"))
                    return
                    ;;
                list)
                    return
                    ;;
                *)
                    COMPREPLY=($(compgen -W "attach list rename delete --help -h" -- "$cur"))
                    return
                    ;;
            esac
            ;;
        pty)
            case "${COMP_WORDS[2]}" in
                kill)
                    COMPREPLY=($(compgen -W "$(_prise_pty_ids)" -- "$cur"))
                    return
                    ;;
                list)
                    return
                    ;;
                *)
                    COMPREPLY=($(compgen -W "list kill --help -h" -- "$cur"))
                    return
                    ;;
            esac
            ;;
        serve)
            return
            ;;
        *)
            COMPREPLY=($(compgen -W "serve session pty --help -h --version -v" -- "$cur"))
            return
            ;;
    esac
}

complete -F _prise prise
