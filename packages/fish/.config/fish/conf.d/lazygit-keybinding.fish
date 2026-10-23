if status is-interactive
    function __fish_lazygit_keybinding
        commandline -f repaint
        command lazygit
        commandline -f repaint
    end

    function __fish_yazi_keybinding
        commandline -f repaint
        y
        commandline -f repaint
    end

    bind \cg __fish_lazygit_keybinding
    bind -M insert \cg __fish_lazygit_keybinding
    bind -M default \cg __fish_lazygit_keybinding

    bind \cy __fish_yazi_keybinding
    bind -M insert \cy __fish_yazi_keybinding
    bind -M default \cy __fish_yazi_keybinding
end
