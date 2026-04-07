# Features to add

- Fail to start server if there are unparseable cells in the buffer
  - search for "app.\_unparsable_cell" or find some other way to detect this cleanly
  - Prompt the user to fix them before trying to run the server
- Run stale cells
- Target and run all markdown cells in the buffer
  - option to automatically execute all markdown cells on marimo start/attach
- Run current cells' dependencies
- Toggle disable/enable on current cell
- Extract code from all cells in the buffer and craft a single script to run
  - prompt the user to deal with elements first:
    1. unparseable cells - include? how to format? comments? something else?
    2. markdown cells - should they be included in the script? If so, how should they be formatted? docstrings? comments? something else?
    3. disabled cells - should they be included in the script? If so, how should they be formatted? comments? something else?
    4. redundant imports, variables, functions, etc. - should they be included in the script? If so, how should they be formatted? comments? something else?

## Feasibility Assessment
