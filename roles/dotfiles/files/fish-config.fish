set -g fish_greeting
set -g fish_cursor_default underscore
set -g fish_cursor_insert underscore
set -g fish_cursor_replace_one underscore
set -g fish_cursor_visual underscore

fish_add_path --prepend ~/.local/bin ~/.npm-global/bin ~/Android/Sdk/platform-tools ~/Android/Sdk/cmdline-tools/latest/bin
set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx ANDROID_HOME "$HOME/Android/Sdk"
set -gx ANDROID_SDK_ROOT "$ANDROID_HOME"
set -gx RUSTC_WRAPPER sccache
set -gx CARGO_INCREMENTAL 0
set -gx SCCACHE_DIR "$HOME/.cache/sccache"

# Every fish sources this file, including `fish -c` and scripts. Those need
# the PATH and variables above, but not the six processes behind a prompt,
# hooks and aliases they never use.
if status is-interactive
    # Keep the prompt icon accurate on Fedora and inside each Distrobox. One
    # builtin read of os-release; the quotes are optional in that format.
    set -l posh_os_id
    set -l posh_os_like
    if test -r /etc/os-release
        while read -l line
            switch $line
                case 'ID=*'
                    set posh_os_id (string replace -r '^ID=' '' -- $line | string trim -c '"\'')
                case 'ID_LIKE=*'
                    set posh_os_like (string replace -r '^ID_LIKE=' '' -- $line | string trim -c '"\'')
            end
        end </etc/os-release
    end
    switch $posh_os_id
        case fedora
            set -gx POSH_OS_ICON ""
        case debian
            set -gx POSH_OS_ICON ""
        case ubuntu
            set -gx POSH_OS_ICON ""
        case arch
            set -gx POSH_OS_ICON ""
        case alpine
            set -gx POSH_OS_ICON ""
        case opensuse-tumbleweed opensuse-leap opensuse
            set -gx POSH_OS_ICON ""
        case '*'
            if string match -q "*debian*" $posh_os_like
                set -gx POSH_OS_ICON ""
            else if string match -q "*rhel*" $posh_os_like; or string match -q "*fedora*" $posh_os_like
                set -gx POSH_OS_ICON ""
            else if string match -q "*arch*" $posh_os_like
                set -gx POSH_OS_ICON ""
            else
                set -gx POSH_OS_ICON ""
            end
    end

    if command -q oh-my-posh
        oh-my-posh init fish --config ~/.config/oh-my-posh/EDM115-newline2.omp.json | source
    end
    if command -q zoxide
        zoxide init fish | source
    end
    if command -q fzf
        fzf --fish | source 2>/dev/null
    end
    if command -q direnv
        direnv hook fish | source
    end

    alias ls='eza --icons'
    alias ll='eza --icons -la'
    alias la='eza --icons -A'
    alias l='eza --icons -CF'
    alias fedora-install='cybex install'
    alias fedora-update='cybex update'
    alias fedora-verify='cybex verify'
    alias update='cybex update'
    alias a='cybex agent'
    # Product default for interactive Codex; `command codex` bypasses this alias.
    alias codex='codex --dangerously-bypass-approvals-and-sandbox'
    alias gs='git status'
    alias ga='git add'
    alias gc='git commit'
    alias gp='git push'
    alias gl='git log --oneline'
    alias lg='lazygit'
    alias hypr-reload='hyprctl reload'
    alias hypr-monitors='hyprctl monitors'
    alias hypr-workspaces='hyprctl workspaces'
    alias ..='cd ..'
    alias ...='cd ../..'
end
