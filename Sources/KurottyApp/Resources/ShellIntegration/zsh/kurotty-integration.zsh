# Kurotty shell integration emits only standard OSC 7 and OSC 133 metadata.
if (( ! ${+_kurotty_shell_integration_loaded} )); then
  typeset -g _kurotty_shell_integration_loaded=1
  typeset -g _kurotty_command_active=0

  autoload -Uz add-zsh-hook

  _kurotty_write_osc() {
    builtin printf '\033]%s\007' "$1"
  }

  _kurotty_report_directory() {
    local encoded_path="${PWD//\%/%25}"
    encoded_path="${encoded_path// /%20}"
    encoded_path="${encoded_path//\#/%23}"
    encoded_path="${encoded_path//\?/%3F}"
    _kurotty_write_osc "7;file://localhost${encoded_path}"
  }

  _kurotty_precmd() {
    local status_code=$?
    if (( _kurotty_command_active )); then
      _kurotty_write_osc "133;D;${status_code}"
      _kurotty_command_active=0
    fi
    _kurotty_report_directory
    _kurotty_write_osc "133;A"
  }

  _kurotty_preexec() {
    _kurotty_command_active=1
    _kurotty_write_osc "133;B"
    _kurotty_write_osc "133;C"
  }

  add-zsh-hook precmd _kurotty_precmd
  add-zsh-hook preexec _kurotty_preexec
fi
