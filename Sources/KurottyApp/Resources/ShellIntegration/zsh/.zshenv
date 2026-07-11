# Kurotty automatic zsh integration. Restore the user's startup directory
# before loading their .zshenv so no machine-specific path is persisted.
if [[ -n "${KUROTTY_ZSH_ZDOTDIR+set}" ]]; then
  builtin export ZDOTDIR="$KUROTTY_ZSH_ZDOTDIR"
  builtin unset KUROTTY_ZSH_ZDOTDIR
else
  builtin unset ZDOTDIR
fi

typeset _kurotty_user_zshenv="${ZDOTDIR:-$HOME}/.zshenv"
if [[ -r "$_kurotty_user_zshenv" ]]; then
  builtin source -- "$_kurotty_user_zshenv"
fi
builtin unset _kurotty_user_zshenv

if [[ -o interactive ]]; then
  builtin source -- "${${(%):-%x}:A:h}/kurotty-integration.zsh"
fi
