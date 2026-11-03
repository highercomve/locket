//! Shell completion for `locket`: the scripts (`locket completion bash |
//! zsh | fish`) and the names they ask for (`locket __complete <what>`).
//!
//!     ~/.bashrc                    eval "$(locket completion bash)"
//!     ~/.zshrc (after compinit)    source <(locket completion zsh)
//!     ~/.config/fish/config.fish   locket completion fish | source
//!
//! Before `--`, the scripts complete Locket's own commands and addresses
//! (projects, workspaces, variables: names only, never values). After
//! `locket run <workspace> ... --`, they hand over to the shell's
//! completion for the command being run, so `locket run hub/prod -- git
//! ch<TAB>` completes like `git ch<TAB>`.
//!
//! `__complete` reads the vault without syncing (a tab press never waits
//! on the network) and prints nothing on errors.
//! @atlas layer: front

const std = @import("std");
const vault = @import("vault.zig");
const sync = @import("sync.zig");

pub const Shell = enum { bash, zsh, fish };

pub fn script(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => bash,
        .zsh => zsh,
        .fish => fish,
    };
}

/// What `__complete` lists.
pub const What = enum {
    /// `project`
    projects,
    /// `project`, `project/workspace`
    workspaces,
    /// `project/NAME`, `project/workspace/NAME`, and the `project/` and
    /// `project/workspace/` prefixes to type a new name after.
    variables,
    /// The variable names of one workspace (`names project[/workspace]`).
    names,
    /// The sync backends' ids.
    backends,

    /// Needs the vault open.
    pub fn needsVault(w: What) bool {
        return w != .backends;
    }
};

/// Writes the candidates for `what`, one per line. `arg`: `names`'s workspace.
pub fn list(v: ?*const vault.Vault, what: What, arg: ?[]const u8, out: *std.Io.Writer) !void {
    if (what == .backends) {
        for (sync.connectors.kinds) |k| try out.print("{s}\n", .{k.id});
        return;
    }
    const s = &(v orelse return).store;
    if (what == .names) {
        const r = vault.Ref.workspaceOf(arg orelse return) catch return;
        const p = s.projects.getPtr(r.project) orelse return;
        const w = p.workspaces.getPtr(r.workspace) orelse return;
        for (w.secrets.keys()) |name| try out.print("{s}\n", .{name});
        return;
    }
    for (s.projects.keys(), s.projects.values()) |pn, p| {
        if (what != .variables) try out.print("{s}\n", .{pn});
        if (what == .projects) continue;
        if (what == .variables) try out.print("{s}/\n", .{pn});
        for (p.workspaces.keys(), p.workspaces.values()) |wn, w| {
            const default = std.mem.eql(u8, wn, vault.default_workspace);
            if (what == .workspaces) {
                if (!default) try out.print("{s}/{s}\n", .{ pn, wn });
                continue;
            }
            // Variables of `default` are addressed without it.
            if (!default) try out.print("{s}/{s}/\n", .{ pn, wn });
            for (w.secrets.keys()) |name| {
                if (default) try out.print("{s}/{s}\n", .{ pn, name }) else try out.print("{s}/{s}/{s}\n", .{ pn, wn, name });
            }
        }
    }
}

const bash =
    \\# locket completion for bash. In ~/.bashrc:  eval "$(locket completion bash)"
    \\_locket() {
    \\    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]} i
    \\    local locket=${COMP_WORDS[0]}
    \\    # After `--`: the completion of the command being run.
    \\    for ((i = 2; i < COMP_CWORD; i++)); do
    \\        if [[ ${COMP_WORDS[i]} == -- ]]; then
    \\            if declare -F _comp_command_offset >/dev/null; then
    \\                _comp_command_offset $((i + 1))
    \\            elif declare -F _command_offset >/dev/null; then
    \\                _command_offset $((i + 1))
    \\            elif ((COMP_CWORD == i + 1)); then
    \\                COMPREPLY=($(compgen -c -- "$cur"))
    \\            else
    \\                COMPREPLY=($(compgen -f -- "$cur"))
    \\            fi
    \\            return
    \\        fi
    \\    done
    \\    local words=""
    \\    if ((COMP_CWORD == 1)); then
    \\        words="ls set get rm run sync update version help completion"
    \\    else
    \\        case ${COMP_WORDS[1]} in
    \\            ls) ((COMP_CWORD == 2)) && words=$("$locket" __complete workspaces 2>/dev/null) ;;
    \\            get|set) ((COMP_CWORD == 2)) && words=$("$locket" __complete variables 2>/dev/null) ;;
    \\            rm)
    \\                case $prev in
    \\                    --workspace) words=$("$locket" __complete workspaces 2>/dev/null) ;;
    \\                    --project) words=$("$locket" __complete projects 2>/dev/null) ;;
    \\                    rm) words="--workspace --project $("$locket" __complete variables 2>/dev/null)" ;;
    \\                esac ;;
    \\            run)
    \\                if ((COMP_CWORD == 2)); then
    \\                    words=$("$locket" __complete workspaces 2>/dev/null)
    \\                elif [[ $prev == --only ]]; then
    \\                    words=$("$locket" __complete names "${COMP_WORDS[2]}" 2>/dev/null)
    \\                else
    \\                    words="--only --prefix --"
    \\                fi ;;
    \\            sync)
    \\                if ((COMP_CWORD == 2)); then
    \\                    words="status now stop setup join backends"
    \\                elif ((COMP_CWORD == 3)) && [[ $prev == setup || $prev == join ]]; then
    \\                    words=$("$locket" __complete backends 2>/dev/null)
    \\                elif ((COMP_CWORD == 4)) && [[ ${COMP_WORDS[2]} == setup || ${COMP_WORDS[2]} == join ]]; then
    \\                    COMPREPLY=($(compgen -d -- "$cur"))
    \\                    return
    \\                fi ;;
    \\            update) words="--check --yes" ;;
    \\            completion) ((COMP_CWORD == 2)) && words="bash zsh fish" ;;
    \\        esac
    \\    fi
    \\    COMPREPLY=($(compgen -W "$words" -- "$cur"))
    \\    # `project/`: keep typing the rest of the address.
    \\    if ((${#COMPREPLY[@]} == 1)) && [[ ${COMPREPLY[0]} == */ ]]; then compopt -o nospace; fi
    \\}
    \\complete -F _locket locket
    \\
;

const zsh =
    \\# locket completion for zsh. In ~/.zshrc, after compinit:  source <(locket completion zsh)
    \\_locket_list() {
    \\    local -a out dirs full
    \\    out=(${(f)"$(${words[1]} __complete "$@" 2>/dev/null)"})
    \\    dirs=(${(M)out:#*/})
    \\    full=(${out:#*/})
    \\    (( $#dirs )) && compadd -S '' -- $dirs
    \\    (( $#full )) && compadd -- $full
    \\}
    \\_locket() {
    \\    local i
    \\    # After `--`: the completion of the command being run.
    \\    for ((i = 3; i < CURRENT; i++)); do
    \\        if [[ ${words[i]} == -- ]]; then
    \\            shift $i words
    \\            (( CURRENT -= i ))
    \\            _normal
    \\            return
    \\        fi
    \\    done
    \\    if (( CURRENT == 2 )); then
    \\        local -a commands=(
    \\            'ls:list projects, workspaces or variables'
    \\            'set:store a variable (the value on stdin)'
    \\            'get:print a variable'"'"'s value'
    \\            'rm:remove a variable, a workspace or a project'
    \\            'run:run a command with a workspace'"'"'s variables'
    \\            'sync:share the vault between machines'
    \\            'update:update Locket'
    \\            'version:print the version'
    \\            'help:show the usage'
    \\            'completion:print the shell completion script'
    \\        )
    \\        _describe -t commands 'locket command' commands
    \\        return
    \\    fi
    \\    local prev=${words[CURRENT-1]}
    \\    case ${words[2]} in
    \\        ls) (( CURRENT == 3 )) && _locket_list workspaces ;;
    \\        get|set) (( CURRENT == 3 )) && _locket_list variables ;;
    \\        rm)
    \\            case $prev in
    \\                --workspace) _locket_list workspaces ;;
    \\                --project) _locket_list projects ;;
    \\                rm) compadd -- --workspace --project; _locket_list variables ;;
    \\            esac ;;
    \\        run)
    \\            if (( CURRENT == 3 )); then
    \\                _locket_list workspaces
    \\            elif [[ $prev == --only ]]; then
    \\                _locket_list names ${words[3]}
    \\            else
    \\                compadd -- --only --prefix --
    \\            fi ;;
    \\        sync)
    \\            if (( CURRENT == 3 )); then
    \\                compadd -- status now stop setup join backends
    \\            elif (( CURRENT == 4 )) && [[ $prev == (setup|join) ]]; then
    \\                _locket_list backends
    \\            elif (( CURRENT == 5 )) && [[ ${words[3]} == (setup|join) ]]; then
    \\                _files -/
    \\            fi ;;
    \\        update) compadd -- --check --yes ;;
    \\        completion) (( CURRENT == 3 )) && compadd -- bash zsh fish ;;
    \\    esac
    \\}
    \\compdef _locket locket
    \\
;

const fish =
    \\# locket completion for fish. In ~/.config/fish/config.fish:  locket completion fish | source
    \\function __locket_tokens
    \\    commandline -opc
    \\end
    \\function __locket_after_dashdash
    \\    contains -- -- (__locket_tokens)[3..-1]
    \\end
    \\# The completed tokens are exactly $argv[1] (locket is 1).
    \\function __locket_at
    \\    test (count (__locket_tokens)) -eq $argv[1]; and not __locket_after_dashdash
    \\end
    \\# The command is one of $argv, and `--` hasn't been typed.
    \\function __locket_is
    \\    set -l t (__locket_tokens)
    \\    test (count $t) -ge 2; and contains -- $t[2] $argv; and not __locket_after_dashdash
    \\end
    \\function __locket_prev
    \\    set -l t (__locket_tokens)
    \\    contains -- $t[-1] $argv
    \\end
    \\# After `--`: the completion of the command being run.
    \\function __locket_command
    \\    set -l t (__locket_tokens)
    \\    set -l i (contains -i -- -- $t[3..-1])
    \\    set i (math $i + 2)
    \\    set -l rest
    \\    if test $i -lt (count $t)
    \\        set rest (string escape -- $t[(math $i + 1)..-1])
    \\    end
    \\    complete -C (string join ' ' -- $rest (commandline -ct))
    \\end
    \\complete -c locket -f
    \\complete -c locket -n '__locket_at 1' -a ls -d 'list projects, workspaces or variables'
    \\complete -c locket -n '__locket_at 1' -a set -d 'store a variable (the value on stdin)'
    \\complete -c locket -n '__locket_at 1' -a get -d "print a variable's value"
    \\complete -c locket -n '__locket_at 1' -a rm -d 'remove a variable, a workspace or a project'
    \\complete -c locket -n '__locket_at 1' -a run -d "run a command with a workspace's variables"
    \\complete -c locket -n '__locket_at 1' -a sync -d 'share the vault between machines'
    \\complete -c locket -n '__locket_at 1' -a update -d 'update Locket'
    \\complete -c locket -n '__locket_at 1' -a version -d 'print the version'
    \\complete -c locket -n '__locket_at 1' -a help -d 'show the usage'
    \\complete -c locket -n '__locket_at 1' -a completion -d 'print the shell completion script'
    \\complete -c locket -n '__locket_is ls; and __locket_at 2' -a '(locket __complete workspaces 2>/dev/null)'
    \\complete -c locket -n '__locket_is get set; and __locket_at 2' -a '(locket __complete variables 2>/dev/null)'
    \\complete -c locket -n '__locket_is rm; and __locket_at 2' -a '--workspace --project (locket __complete variables 2>/dev/null)'
    \\complete -c locket -n '__locket_is rm; and __locket_prev --workspace' -a '(locket __complete workspaces 2>/dev/null)'
    \\complete -c locket -n '__locket_is rm; and __locket_prev --project' -a '(locket __complete projects 2>/dev/null)'
    \\complete -c locket -n '__locket_is run; and __locket_at 2' -a '(locket __complete workspaces 2>/dev/null)'
    \\complete -c locket -n '__locket_is run; and __locket_prev --only' -a '(locket __complete names (__locket_tokens)[3] 2>/dev/null)'
    \\complete -c locket -n '__locket_is run; and not __locket_at 2; and not __locket_prev --only' -a '--only --prefix --'
    \\complete -c locket -n '__locket_after_dashdash' -a '(__locket_command)'
    \\complete -c locket -n '__locket_is sync; and __locket_at 2' -a 'status now stop setup join backends'
    \\complete -c locket -n '__locket_is sync; and __locket_at 3; and __locket_prev setup join' -a '(locket __complete backends 2>/dev/null)'
    \\complete -c locket -n '__locket_is sync; and __locket_at 4' -a '(__fish_complete_directories)'
    \\complete -c locket -n '__locket_is update' -a '--check --yes'
    \\complete -c locket -n '__locket_is completion; and __locket_at 2' -a 'bash zsh fish'
    \\
;

test list {
    const a = std.testing.allocator;
    var s: vault.Store = .{};
    defer @import("store.zig").free(a, &s);
    var p: @import("store.zig").Project = .{ .description = try a.dupe(u8, "") };
    try @import("store.zig").ensureDefault(a, &p);
    const def = p.workspaces.getPtr(vault.default_workspace).?;
    try def.secrets.put(a, try a.dupe(u8, "API"), .{ .value = try a.dupe(u8, "x") });
    var prod: @import("store.zig").Workspace = .{};
    try prod.secrets.put(a, try a.dupe(u8, "TOKEN"), .{ .value = try a.dupe(u8, "y") });
    try p.workspaces.put(a, try a.dupe(u8, "prod"), prod);
    try s.projects.put(a, try a.dupe(u8, "hub"), p);

    var v: vault.Vault = undefined;
    v.store = s;
    var buf: std.Io.Writer.Allocating = .init(a);
    defer buf.deinit();
    try list(&v, .workspaces, null, &buf.writer);
    try std.testing.expectEqualStrings("hub\nhub/prod\n", buf.written());
    buf.clearRetainingCapacity();
    try list(&v, .variables, null, &buf.writer);
    try std.testing.expectEqualStrings("hub/\nhub/API\nhub/prod/\nhub/prod/TOKEN\n", buf.written());
    buf.clearRetainingCapacity();
    try list(&v, .names, "hub/prod", &buf.writer);
    try std.testing.expectEqualStrings("TOKEN\n", buf.written());
    buf.clearRetainingCapacity();
    try list(null, .backends, null, &buf.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "nomadfs\n") != null);
    // No value is ever listed.
    try list(&v, .variables, null, &buf.writer);
    try std.testing.expect(std.mem.indexOf(u8, buf.written(), "x\n") == null);
}
