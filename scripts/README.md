# Scripts Directory

Organized development and utility scripts for the Cinegraph project.

## Directory Structure

```
scripts/
├── analysis/          # Data analysis and investigation scripts
├── data_import/       # Database population and import utilities
├── testing/          # Testing and validation scripts
├── archive/          # Archived temporary/debug scripts (moved from root)
├── *.sh             # Shell utilities (clear_database.sh, etc.)
└── *.exs            # Elixir utility scripts
```

## Guidelines

- Keep the project root clean of temporary files
- Use proper subdirectories for script organization
- Archive old debugging/temporary scripts instead of deleting
- Document script purposes in comments or README files

## Archived Files

The `archive/` directory contains temporary debugging and test scripts that were previously cluttering the project root. These files have been preserved but moved out of the main context to improve performance.