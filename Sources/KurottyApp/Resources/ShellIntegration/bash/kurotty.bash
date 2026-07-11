# Kurotty starts bash with this rcfile so shell integration is installation-local.
if [[ $- == *i* ]]; then
  if [[ -r /etc/profile ]]; then
    builtin source /etc/profile
  fi
  for _kurotty_profile in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    if [[ -r "$_kurotty_profile" ]]; then
      builtin source "$_kurotty_profile"
      break
    fi
  done
  builtin unset _kurotty_profile

  __kurotty_command_active=0
  __kurotty_in_prompt=1
  __kurotty_original_prompt_command=${PROMPT_COMMAND-}

  __kurotty_write_osc() {
    builtin printf '\033]%s\007' "$1"
  }

  __kurotty_report_directory() {
    local encoded_path=${PWD//%/%25}
    encoded_path=${encoded_path// /%20}
    encoded_path=${encoded_path//#/%23}
    encoded_path=${encoded_path//\?/%3F}
    __kurotty_write_osc "7;file://localhost${encoded_path}"
  }

  __kurotty_prompt_wrapper() {
    local status_code=$?
    __kurotty_in_prompt=1
    if [[ $__kurotty_command_active == 1 ]]; then
      __kurotty_write_osc "133;D;${status_code}"
      __kurotty_command_active=0
    fi
    __kurotty_report_directory
    __kurotty_write_osc "133;A"
    if [[ -n $__kurotty_original_prompt_command ]]; then
      builtin eval "$__kurotty_original_prompt_command"
    fi
    __kurotty_in_prompt=0
  }

  __kurotty_debug_trap() {
    [[ $__kurotty_in_prompt == 1 ]] && return
    [[ ${FUNCNAME[1]-} == __kurotty_prompt_wrapper ]] && return
    if [[ $__kurotty_command_active == 0 ]]; then
      __kurotty_command_active=1
      __kurotty_write_osc "133;B"
      __kurotty_write_osc "133;C"
    fi
  }

  PROMPT_COMMAND=__kurotty_prompt_wrapper
  if [[ -z $(builtin trap -p DEBUG) ]]; then
    builtin trap '__kurotty_debug_trap' DEBUG
  fi
fi
