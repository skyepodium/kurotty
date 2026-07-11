# Kurotty automatic fish integration, loaded through XDG_DATA_DIRS.
if not set -q __kurotty_shell_integration_loaded
    set -g __kurotty_shell_integration_loaded 1
    set -g __kurotty_command_active 0

    function __kurotty_write_osc
        printf '\e]%s\a' "$argv[1]"
    end

    function __kurotty_report_directory
        set -l encoded_path (string escape --style=url -- $PWD)
        __kurotty_write_osc "7;file://localhost$encoded_path"
    end

    function __kurotty_preexec --on-event fish_preexec
        set -g __kurotty_command_active 1
        __kurotty_write_osc '133;B'
        __kurotty_write_osc '133;C'
    end

    function __kurotty_prompt --on-event fish_prompt
        set -l status_code $status
        if test $__kurotty_command_active -eq 1
            __kurotty_write_osc "133;D;$status_code"
            set -g __kurotty_command_active 0
        end
        __kurotty_report_directory
        __kurotty_write_osc '133;A'
    end
end
