#!/usr/bin/env python3
"""
nvim_bridge.py — bidirectional Neovim control for Claude Code.

Connects to a running Neovim instance via socket and exposes
high-level operations: open files, harpoon, marks, trailblazer,
kulala HTTP requests, scoped grep, and state queries.

Usage:
    python3 nvim_bridge.py <command> [args...]

Socket discovery order:
    1. $NVIM_LISTEN_ADDRESS
    2. /tmp/nvim-server.pipe  (user's alias default)
    3. $NVIM  (when running inside nvim terminal)

Commands:
    open <file> [line]              Open file, optionally jump to line
    open_many <file1> <file2> ...   Open multiple files as buffers
    harpoon_add [file]              Add current or specified file to harpoon list
    harpoon_list                    Show current harpoon list
    mark <letter> [file] [line]     Set a global mark (A-Z)
    trail <file> <line>             Drop a trailblazer mark at file:line
    kulala <file.http>              Open an .http file for kulala
    kulala_gen <outfile> <json>     Generate .http file from JSON spec
    grip_connect [url]              Connect to database (or open picker)
    grip_open <table|path> [flags]  Open table/file in Grip grid
    grip_query [sql]                Open query pad, optionally with SQL
    grip_tables                     Fuzzy table picker
    grip_schema                     Toggle schema browser sidebar
    grip_attach <conn> <alias>      Attach DB for cross-DB federation
    grip_gen <outfile.md> <json>    Generate SQL notebook from JSON spec
    grip_home                       Open Grip home screen
    scoped_grep <title> <f1> ...    Launch scoped grep on file list
    buffers                         List open buffers
    cursor                          Get current cursor position
    state                           Dump editor state (buffers, cursor, cwd)
    exec <lua_code>                 Execute arbitrary Lua in Neovim
    cmd <vim_command>               Execute an ex command
"""

import json
import os
import sys

import pynvim


def find_sibling_nvim_socket():
    """Find nvim in a sibling tmux pane and return its --listen socket path."""
    import subprocess
    tmux_pane = os.environ.get("TMUX_PANE")
    if not tmux_pane:
        return None
    # Get the window ID for our pane
    try:
        win_id = subprocess.check_output(
            ["tmux", "display-message", "-p", "#{window_id}"],
            text=True
        ).strip()
        # List all panes in this window
        panes = subprocess.check_output(
            ["tmux", "list-panes", "-t", win_id, "-F",
             "#{pane_id} #{pane_pid} #{pane_current_command}"],
            text=True
        ).strip().splitlines()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None

    for pane_line in panes:
        parts = pane_line.split(None, 2)
        if len(parts) < 3:
            continue
        pane_id, pane_pid, cmd = parts
        if pane_id == tmux_pane:
            continue  # skip our own pane
        if cmd != "nvim":
            continue
        # Found an nvim sibling — walk its process tree for --listen sockets
        # Check if this nvim or its children have a known socket
        try:
            # Get child PIDs (nvim forks)
            children = subprocess.check_output(
                ["pgrep", "-P", pane_pid], text=True
            ).strip().splitlines()
        except subprocess.CalledProcessError:
            children = []
        pids_to_check = [pane_pid] + children
        for pid in pids_to_check:
            try:
                cmdline = subprocess.check_output(
                    ["ps", "-p", pid, "-o", "args="], text=True
                ).strip()
            except subprocess.CalledProcessError:
                continue
            if "--listen" in cmdline:
                # Extract the socket path after --listen
                parts = cmdline.split("--listen")
                if len(parts) > 1:
                    sock = parts[1].strip().split()[0]
                    if os.path.exists(sock):
                        return sock
    return None


def connect():
    candidates = [
        os.environ.get("NVIM_LISTEN_ADDRESS"),
        os.environ.get("NVIM"),
        find_sibling_nvim_socket(),
        "/tmp/nvim-server.pipe",
    ]
    for sock in candidates:
        if sock and os.path.exists(sock):
            try:
                return pynvim.attach("socket", path=sock)
            except Exception:
                continue
    print("ERROR: No running Neovim instance found.", file=sys.stderr)
    print("Start nvim with: nvim --listen /tmp/nvim-server.pipe", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_open(nvim, args):
    """Open a file, optionally at a line number."""
    if not args:
        print("Usage: open <file> [line]", file=sys.stderr)
        sys.exit(1)
    filepath = os.path.abspath(args[0])
    line = int(args[1]) if len(args) > 1 else None
    nvim.command(f"edit {filepath}")
    if line:
        nvim.command(f"{line}")
        nvim.command("normal! zz")
    print(f"Opened {filepath}" + (f" at line {line}" if line else ""))


def cmd_open_many(nvim, args):
    """Open multiple files as buffers."""
    if not args:
        print("Usage: open_many <file1> <file2> ...", file=sys.stderr)
        sys.exit(1)
    for f in args:
        filepath = os.path.abspath(f)
        nvim.command(f"badd {filepath}")
    # Focus the first one
    nvim.command(f"edit {os.path.abspath(args[0])}")
    print(f"Opened {len(args)} buffers")


def cmd_harpoon_add(nvim, args):
    """Add file to harpoon2 list."""
    if args:
        filepath = os.path.abspath(args[0])
        nvim.command(f"edit {filepath}")
    nvim.exec_lua('require("harpoon"):list():add()', [])
    name = nvim.call("expand", "%:t")
    print(f"Added {name} to harpoon")


def cmd_harpoon_list(nvim, args):
    """Show current harpoon list."""
    items = nvim.exec_lua("""
        local list = require("harpoon"):list()
        local result = {}
        for i, item in ipairs(list.items) do
            table.insert(result, { index = i, value = item.value })
        end
        return result
    """, [])
    if not items:
        print("Harpoon list is empty")
        return
    for item in items:
        print(f"  {item['index']}: {item['value']}")


def cmd_mark(nvim, args):
    """Set a global mark (A-Z) at file:line."""
    if not args:
        print("Usage: mark <letter> [file] [line]", file=sys.stderr)
        sys.exit(1)
    letter = args[0].upper()
    if len(letter) != 1 or not letter.isalpha():
        print("ERROR: mark must be a single letter A-Z", file=sys.stderr)
        sys.exit(1)

    if len(args) >= 2:
        filepath = os.path.abspath(args[1])
        nvim.command(f"edit {filepath}")
    if len(args) >= 3:
        line = int(args[2])
        nvim.command(f"{line}")

    nvim.command(f"normal! m{letter}")
    pos = nvim.call("getpos", f"'{letter}")
    print(f"Set mark {letter} at line {pos[1]}")


def cmd_trail(nvim, args):
    """Drop a trailblazer mark at file:line."""
    if len(args) < 2:
        print("Usage: trail <file> <line>", file=sys.stderr)
        sys.exit(1)
    filepath = os.path.abspath(args[0])
    line = int(args[1])
    nvim.command(f"edit {filepath}")
    nvim.command(f"{line}")
    nvim.exec_lua('require("trailblazer").new_trail_mark()', [])
    print(f"Trail mark at {os.path.basename(filepath)}:{line}")


def cmd_kulala(nvim, args):
    """Open an .http file for kulala."""
    if not args:
        print("Usage: kulala <file.http>", file=sys.stderr)
        sys.exit(1)
    filepath = os.path.abspath(args[0])
    nvim.command(f"edit {filepath}")
    print(f"Opened {filepath} (use <leader>Rs to send)")


def cmd_kulala_gen(nvim, args):
    """Generate an .http file from a JSON spec and open it.

    JSON spec format:
    [
      {"method": "GET", "url": "...", "headers": {"k": "v"}, "body": "..."},
      ...
    ]
    """
    if len(args) < 2:
        print("Usage: kulala_gen <outfile.http> <json_spec>", file=sys.stderr)
        sys.exit(1)
    outfile = os.path.abspath(args[0])
    spec = json.loads(args[1])

    lines = []
    for i, req in enumerate(spec):
        if i > 0:
            lines.append("###")
            lines.append("")
        method = req.get("method", "GET")
        url = req["url"]
        name = req.get("name", f"{method} {url}")
        lines.append(f"# {name}")
        lines.append(f"{method} {url}")
        for k, v in req.get("headers", {}).items():
            lines.append(f"{k}: {v}")
        body = req.get("body")
        if body:
            lines.append("")
            lines.append(body if isinstance(body, str) else json.dumps(body, indent=2))
        lines.append("")

    with open(outfile, "w") as f:
        f.write("\n".join(lines))

    nvim.command(f"edit {outfile}")
    print(f"Generated {outfile} with {len(spec)} request(s)")


def cmd_grip_connect(nvim, args):
    """Connect to a database via dadbod-grip.

    With URL: connects directly.
    Without: opens connection picker.
    URL formats: postgresql://user:pass@host:5432/db, sqlite:path.db, duckdb:path.duckdb
    """
    if not args:
        nvim.command("GripConnect")
        print("Opened connection picker")
        return
    url = args[0]
    nvim.command(f"GripConnect {url}")
    print(f"Connected to {url}")


def cmd_grip_open(nvim, args):
    """Open a table or file in dadbod-grip grid.

    Accepts table names, file paths (.csv, .parquet, .json, .xlsx), or URLs.
    Flags: --write (enable edits), --watch[=interval] (auto-refresh).
    """
    if not args:
        print("Usage: grip_open <table_or_path> [--write] [--watch[=interval]]", file=sys.stderr)
        sys.exit(1)
    nvim.command(f"Grip {' '.join(args)}")
    print(f"Opened {args[0]} in Grip grid")


def cmd_grip_query(nvim, args):
    """Open Grip query pad, optionally prepopulated with SQL."""
    if args:
        sql = " ".join(args)
        nvim.command(f"GripQuery {sql}")
        print("Opened query pad with SQL")
    else:
        nvim.command("GripQuery")
        print("Opened query pad")


def cmd_grip_tables(nvim, args):
    """Open Grip fuzzy table picker."""
    nvim.command("GripTables")
    print("Opened table picker")


def cmd_grip_schema(nvim, args):
    """Toggle Grip schema browser sidebar."""
    nvim.command("GripSchema")
    print("Toggled schema sidebar")


def cmd_grip_attach(nvim, args):
    """Attach a database for cross-DB federation via DuckDB.

    Format: grip_attach <type>:<connection_details> <alias>
    Example: grip_attach postgres:dbname=sales host=localhost user=me pg
    Then query as: SELECT pg.table.col FROM pg.table
    """
    if len(args) < 2:
        print("Usage: grip_attach <connection_string> <alias>", file=sys.stderr)
        sys.exit(1)
    conn = args[0]
    alias = args[1]
    nvim.command(f"GripAttach {conn} {alias}")
    print(f"Attached {conn} as '{alias}'")


def cmd_grip_gen(nvim, args):
    """Generate a SQL notebook (.md with sql fences) and open it.

    JSON spec format:
    [
      {"name": "Section title", "sql": "SELECT ...", "description": "optional context"},
      ...
    ]
    User executes blocks with <C-CR> in Grip. Load via gn in query pad.
    """
    if len(args) < 2:
        print("Usage: grip_gen <outfile.md> <json_spec>", file=sys.stderr)
        sys.exit(1)
    outfile = os.path.abspath(args[0])
    spec = json.loads(args[1])

    lines = []
    lines.append("# SQL Notebook")
    lines.append("")
    lines.append("> Execute blocks with `<C-CR>`. Load via `gn` in query pad.")
    lines.append("")

    for i, query in enumerate(spec):
        name = query.get("name", f"Query {i + 1}")
        lines.append(f"## {name}")
        lines.append("")
        desc = query.get("description")
        if desc:
            lines.append(desc)
            lines.append("")
        lines.append("```sql")
        lines.append(query["sql"])
        lines.append("```")
        lines.append("")

    with open(outfile, "w") as f:
        f.write("\n".join(lines))

    nvim.command(f"edit {outfile}")
    print(f"Generated {outfile} with {len(spec)} queries")


def cmd_grip_home(nvim, args):
    """Open Grip home / welcome screen."""
    nvim.command("GripHome")
    print("Opened Grip home")


def cmd_scoped_grep(nvim, args):
    """Launch scoped grep picker on a set of files."""
    if len(args) < 2:
        print("Usage: scoped_grep <title> <file1> [file2] ...", file=sys.stderr)
        sys.exit(1)
    title = args[0]
    files = [os.path.abspath(f) for f in args[1:]]
    files_lua = "{" + ",".join(f'"{f}"' for f in files) + "}"
    nvim.exec_lua(
        f'require("lib.scoped-grep").grep_files({files_lua}, "{title}")', []
    )
    print(f"Scoped grep: {title} ({len(files)} files)")


def cmd_buffers(nvim, args):
    """List open buffers."""
    bufs = nvim.exec_lua("""
        local result = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].buflisted then
                local name = vim.api.nvim_buf_get_name(buf)
                if name ~= "" then
                    table.insert(result, {
                        id = buf,
                        name = vim.fn.fnamemodify(name, ":~:."),
                        modified = vim.bo[buf].modified,
                    })
                end
            end
        end
        return result
    """, [])
    for b in bufs:
        mod = " [+]" if b.get("modified") else ""
        print(f"  {b['id']:3d}: {b['name']}{mod}")


def cmd_cursor(nvim, args):
    """Get current cursor position."""
    pos = nvim.call("getcurpos")
    filepath = nvim.call("expand", "%:p")
    print(json.dumps({
        "file": filepath,
        "line": pos[1],
        "col": pos[2],
    }))


def cmd_state(nvim, args):
    """Dump full editor state."""
    state = nvim.exec_lua("""
        local bufs = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[buf].buflisted then
                local name = vim.api.nvim_buf_get_name(buf)
                if name ~= "" then
                    table.insert(bufs, vim.fn.fnamemodify(name, ":~:."))
                end
            end
        end
        local pos = vim.fn.getcurpos()
        return {
            cwd = vim.fn.getcwd(),
            file = vim.fn.expand("%:p"),
            line = pos[2],
            col = pos[3],
            buffers = bufs,
            buf_count = #bufs,
        }
    """, [])
    print(json.dumps(state, indent=2))


def cmd_exec(nvim, args):
    """Execute arbitrary Lua code."""
    if not args:
        print("Usage: exec <lua_code>", file=sys.stderr)
        sys.exit(1)
    code = " ".join(args)
    result = nvim.exec_lua(f"return {code}", [])
    if result is not None:
        print(json.dumps(result, indent=2) if isinstance(result, (dict, list)) else result)


def cmd_cmd(nvim, args):
    """Execute a vim ex command."""
    if not args:
        print("Usage: cmd <vim_command>", file=sys.stderr)
        sys.exit(1)
    nvim.command(" ".join(args))
    print("OK")


COMMANDS = {
    "open": cmd_open,
    "open_many": cmd_open_many,
    "harpoon_add": cmd_harpoon_add,
    "harpoon_list": cmd_harpoon_list,
    "mark": cmd_mark,
    "trail": cmd_trail,
    "kulala": cmd_kulala,
    "kulala_gen": cmd_kulala_gen,
    "grip_connect": cmd_grip_connect,
    "grip_open": cmd_grip_open,
    "grip_query": cmd_grip_query,
    "grip_tables": cmd_grip_tables,
    "grip_schema": cmd_grip_schema,
    "grip_attach": cmd_grip_attach,
    "grip_gen": cmd_grip_gen,
    "grip_home": cmd_grip_home,
    "scoped_grep": cmd_scoped_grep,
    "buffers": cmd_buffers,
    "cursor": cmd_cursor,
    "state": cmd_state,
    "exec": cmd_exec,
    "cmd": cmd_cmd,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    command = sys.argv[1]
    if command not in COMMANDS:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(f"Available: {', '.join(COMMANDS)}", file=sys.stderr)
        sys.exit(1)

    nvim = connect()
    COMMANDS[command](nvim, sys.argv[2:])


if __name__ == "__main__":
    main()
